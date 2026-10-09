# Notas de diseño para F5 (solo diseño: NO ejecutado, NO implementado)

## 1. Prueba de caída controlada (requiere el OK explícito de Juan antes de correrla)

**Objetivo:** con el worker nuevo conectado, cortar la ruta hacia RabbitMQ ~2 min, restaurarla y medir
(a) las líneas que emite el consumer al perder y al recuperar, (b) el tiempo hasta volver a ser consumidor
activo, (c) cómo lo clasifica el vigilante.

**Por qué importa (hallazgo previo, 9-oct):** en el worker actual, tras «Connection … closed. Reconnecting»
el log **no** mostró ninguna línea de recuperación (la única «Consumidor … arrancado» apareció tras reiniciar el
contenedor). Si la recuperación es silenciosa, la heurística actual del vigilante («Reconnecting» sin «arrancado»
⇒ `CONSUMER_CAIDO`) clasificaría mal un consumer ya recuperado y lo reiniciaría sin necesidad. **Hasta medir esto,
el vigilante no debe reiniciar solo por patrones de log**: reiniciar únicamente con `unhealthy` o con pérdida que
persista > N min (p. ej. 10) con el host TCP alcanzable.

**Método del corte (dos variantes, una a la vez):**

| Variante | Qué simula | Cómo (camino b: VM de WSL) | Restauración |
|---|---|---|---|
| DROP | red muerta en silencio (suspensión, Tailscale caído): se detecta por heartbeat (`heartbeat=30` ⇒ ~2 min) | `iptables -I DOCKER-USER -d <ip-rabbit> -p tcp --dport 5672 -j DROP` en la VM | `iptables -D DOCKER-USER …` |
| REJECT | puerto cerrado / broker caído («Connection refused», visto el 9-oct 17:05) | igual con `-j REJECT --reject-with tcp-reset` | idem |

En el PC de Juan (Docker Desktop, camino actual) la alternativa es `tailscale down` / `tailscale up`, que además
corta su acceso a la BD por Tailscale: usar solo si se acepta.

**Seguro de restauración (obligatorio):** antes de cortar, lanzar un proceso **independiente** que restaure
pase lo que pase (p. ej. `sleep 150; iptables -D …` desacoplado), de modo que un fallo de la sesión no deje el
worker cortado.

**Medidas:**
- (a) `docker logs --timestamps` desde 1 min antes del corte hasta 3 min después de restaurar (líneas de pérdida
  y de recuperación, tal cual, sin interpretar).
- (b) Instante de restauración → instante en que RabbitMQ lista de nuevo al consumer con `x-priority=10`
  (`rabbitmqctl list_consumers`, **solo lectura**, por SSH con autorización de fase), sondeando cada 5 s.
  Opcional: un mensaje real por el dominio público para ver quién lo atiende.
- (c) `vigilante.ps1` en modo diagnóstico (sin `-Aplicar`) cada 30 s durante toda la prueba: esperado
  `OK → SIN_RUTA` (corte) `→ OK` (recuperado). Cualquier paso por `CONSUMER_CAIDO` tras recuperarse es el
  falso positivo descrito arriba.

**Efecto en producción:** mientras dura el corte, los mensajes los atiende el consumer del VPS (prioridad 0): sin
pérdida, pero respuestas con el modelo del VPS. Avisar antes y elegir una hora de poco uso.

## 2. Entrega de la contraseña SIN variable de entorno del contenedor (camino b)

**Problema:** hoy `RABBITMQ_URL` se pasa como variable de entorno del contenedor ⇒ aparece en `docker inspect`
y en `…/containers/<id>/config.v2.json`. El código del chatbot (no se toca) lee `RABBITMQ_URL` de `os.environ` al
importar `app.main`, así que el proceso necesita esa variable… pero no el *contenedor*.

**Diseño:**
1. **Archivo en tmpfs dentro de la VM de WSL.** `/run` es tmpfs (RAM; no toca el disco virtual). El script de
   SYSTEM, tras descifrar con DPAPI, escribe `/run/techo360/rabbit.url` (dir `0700`, archivo `0400`, root) **por
   stdin**, nunca por línea de comandos ni variable:
   `System.Diagnostics.Process` sobre `wsl.exe -d techo360 -u root -- sh -c 'umask 077; mkdir -p /run/techo360; cat > /run/techo360/rabbit.url'`
   con `RedirectStandardInput` y bytes UTF-8 **sin BOM ni salto de línea** escritos en `StandardInput.BaseStream`.
   La URL (`amqp://usuario:<pass url-encoded>@<host elegido>:5672/?heartbeat=30`) se arma en memoria con
   `Select-RabbitHost` + `Get-WorkerSecret`.
2. **Montaje de solo lectura del directorio** (no del archivo: un reemplazo atómico rompería el montaje por inodo):
   `-v /run/techo360:/run/secrets:ro`. En el compose: `RABBITMQ_URL_FILE: /run/secrets/rabbit.url` (ruta, no secreto);
   se elimina `RABBITMQ_URL` del `environment`.
3. **Entrypoint en `Dockerfile.worker`** (el Dockerfile del chatbot no se toca):
   ```sh
   #!/bin/sh
   set -eu
   f="${RABBITMQ_URL_FILE:?falta RABBITMQ_URL_FILE}"
   [ -r "$f" ] || { echo "entrypoint: no existe $f (el script de SYSTEM no lo escribio todavia)" >&2; exit 78; }
   RABBITMQ_URL="$(cat "$f")"; export RABBITMQ_URL
   exec "$@"            # CMD uvicorn app.main:app …
   ```
   `ENTRYPOINT ["/entrypoint.sh"]` + `COPY entrypoint.sh` con permisos de ejecución. Nunca imprime el valor.
4. **Orden en cada arranque (SYSTEM):** distro WSL arriba → dockerd arriba → descifrar DPAPI → escribir el archivo
   → `docker start`/`compose up`. Si el vigilante cambia de host (p. ej. cae la IP privada y pasa a Tailscale) debe
   **reescribir el archivo y reiniciar** el contenedor (el entrypoint lo lee solo al arrancar).
5. **Reinicios automáticos de Docker:** `restart: unless-stopped` re-ejecuta el entrypoint mientras el archivo
   siga en `/run` (vive mientras viva la VM). Tras un reinicio de la VM el archivo no existe ⇒ el contenedor sale
   con 78 hasta que el script de SYSTEM lo reescriba (comportamiento deseado, visible como estado).

**Lo que mejora y lo que NO:**
- Mejora: la contraseña ya no está en `docker inspect`, ni en la configuración del contenedor, ni en el disco de la VM.
- Residual (aceptado y documentado): el proceso `uvicorn` sí tiene `RABBITMQ_URL` en su entorno ⇒ `/proc/<pid>/environ`
  dentro de la VM, legible por **root de la VM** (quien administre el equipo ya podía extraerla; ver modelo de
  amenazas). Los logs de aio-pika la enmascaran (`******`, comprobado en el log real).
- Memoria de la VM → swap: fijar `swap=0` en el `.wslconfig` de la cuenta SYSTEM
  (`C:\Windows\System32\config\systemprofile\.wslconfig`) para que no acabe en un archivo de intercambio.

**Validación con `Find-SecretLeak` (pendiente de implementar):** añadir `-WslDistro <nombre>` que busque dentro de
la VM pasando el patrón **por stdin** (`read -r PAT` y `grep -rIlF -e "$PAT"` sobre `/run /etc /tmp /root /var/log
/var/lib/docker/containers`), más `/proc/*/cmdline` y `/proc/*/environ`. Resultado esperado:
- `docker inspect` y `config.v2.json`: **limpios**.
- `/run/techo360/rabbit.url`: presente (es el diseño) — se reporta como «esperado».
- `/proc/<uvicorn>/environ`: presente — «residual aceptado».
- Cualquier otra ubicación (Windows: árbol de instalación, `%ProgramData%`, logs, Registro de Eventos, historial de
  PowerShell, entorno del sistema, tareas programadas) ⇒ **fallo**.
Limitación: durante la búsqueda el patrón aparece unos instantes en la línea de comandos del propio `grep` dentro de
la VM; es una herramienta de verificación ejecutada por un administrador, no del servicio.
