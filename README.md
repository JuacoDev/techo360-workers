# techo360-workers

Pool de workers de chatbot (Ollama + consumer de RabbitMQ) para máquinas
fuera del VPS -- primera validación con el PC del desarrollador,
pensado para escalar a 6+ máquinas de laboratorio de la universidad.

**Este repo NO reimplementa el chatbot.** Reutiliza tal cual la imagen
de [`techo360-chatbot`](https://github.com/JuacoDev/techo360-chatbot)
(mismo `Dockerfile`, mismo `app/rabbitmq_consumer.py`) -- solo la
empaqueta para correr en otra máquina. Cualquier cambio de
comportamiento del chatbot va en ese repo, nunca en este.

## Por qué repo aparte (y no una carpeta de techo360-infra)

`techo360-infra` orquesta el VPS (docker-compose de los 5 servicios de
producción). Este repo tiene un ciclo de vida distinto: instalador para
Windows, configuración por sitio (laboratorio), y va a crecer con
lógica propia de reconexión/gestión de flota que no tiene sentido
mezclar con el compose del VPS.

## Requisitos

- Docker Desktop (el instalador lo verifica/instala).
- El repo `techo360-chatbot` clonado como **hermano** de este (mismo
  patrón que `techo360-infra` usa `context: ../techo360-chatbot`):
  ```
  techo360/
    techo360-chatbot/
    techo360-workers/   <- este repo
  ```
- El GGUF de producción en `models/techo360-v3.2-Q4_K_M.gguf` (junto a
  este instalador, sin trackear por git -- ver `.gitignore`, 1.9G es
  demasiado pesado para el historial). Movido aquí el 27-sep-2026 desde
  `techo360-chatbot/training/modelo_gguf/` al limpiar ese repo de
  artefactos de entrenamiento. Para labs reales hace falta hornear el
  modelo dentro de la imagen Docker (ver más abajo) en vez de depender
  de este archivo local.
- Credenciales del usuario RabbitMQ `techo360-worker` (ver
  "Usuario de RabbitMQ" abajo) -- **nunca** las credenciales que ya usa
  el chatbot del VPS.

## Instalación

Doble clic en `install-worker.exe` (compilado con `ps2exe` desde
`install-worker.ps1`, ver más abajo). Si ya existe `.env` en la carpeta
(caso normal: credenciales fijas del pool, generadas una vez), lo usa
tal cual y no pide nada -- instalación de doble clic, sin intervención.
Sin `.env`, pide la contraseña de forma interactiva (nunca en texto
plano en el historial).

Verifica Docker, construye la imagen del worker, importa el modelo de
Ollama, arranca el contenedor, y verifica en el log real que el
consumer confirmó conexión (`x-priority=10`) -- no se conforma con
"container running".

Uso directo del script (equivalente, para depurar):
```powershell
.\install-worker.ps1 -RabbitMqHost 100.116.197.118
```

### Compilar el .exe

```powershell
Install-Module ps2exe -Scope CurrentUser  # una sola vez
Invoke-ps2exe -inputFile install-worker.ps1 -outputFile install-worker.exe -title "Techo 360 - Worker de Chatbot" -requireAdmin
```

`-requireAdmin` porque instalar Docker Desktop / manejar contenedores
requiere privilegios elevados. El `.exe` no se commitea (ver
`.gitignore`) -- se recompila desde el script o se distribuye aparte.

`RABBITMQ_HOST` es el **único** valor pensado para cambiar entre esta
prueba (IP de Tailscale del VPS) y el despliegue final de laboratorio
(IP privada de la universidad, `10.154.12.191` -- **todavía no
configurada en RabbitMQ**, es tarea aparte). Usuario/password se
mantienen iguales para todo el pool.

## Usuario de RabbitMQ (`techo360-worker`)

Usuario nuevo, exclusivo para el pool de workers, sin el tag de
administrador (no puede entrar al panel de management). Permisos
mínimos en el vhost `/` -- mismo alcance que ya tiene el chatbot del
VPS, ni más ni menos:

| Permiso   | Regex                                                          | Para qué |
|-----------|-----------------------------------------------------------------|----------|
| configure | `^(chatbot_requests\|chatbot_eventos_persistencia)?$`          | declarar/pasar por alto ambas colas |
| write     | `^(chatbot_requests\|chatbot_eventos_persistencia\|amq\.default)$` | publicar eventos + responder RPC por el exchange por defecto |
| read      | `^chatbot_requests$`                                           | consumir la cola de solicitudes |

`amq.default` es el nombre real que RabbitMQ usa para el chequeo de
permisos del exchange por defecto (aunque en AMQP se declare/publique
con nombre vacío `""`) -- confirmado real al validar el primer worker:
sin este permiso, el consumer recibía el mensaje y generaba la
respuesta con Ollama, pero RabbitMQ rechazaba publicarla de vuelta
(`ACCESS_REFUSED - write access to exchange 'amq.default' ... refused`).

Se crea/actualiza con `techo360-infra/scripts/rabbitmq-worker-user.sh`,
que corre como parte de `deploy-infra.sh` (paso 5) en cada push a
`development` de ese repo -- via el runner self-hosted del VPS, nunca
SSH manual. Requiere el secret de repo `WORKER_RABBITMQ_PASSWORD`
configurado de antemano. Un workflow liviano aparte
(`diagnose-rabbitmq.yml`, disparado con un push a `.trigger-diagnose`)
imprime `rabbitmqctl list_consumers` para verificar en cualquier
momento quién está consumiendo `chatbot_requests` y con qué prioridad,
sin disparar el pipeline pesado de `deploy-infra.sh`.

### Nota sobre logs del consumer

`techo360-chatbot` no tenía `logging.basicConfig` configurado, así que
los `logger.info(...)` de `app/rabbitmq_consumer.py` (incluida la
confirmación de arranque con su `x-priority`) nunca aparecían en
`docker logs` -- se corrigió en ese repo (`app/main.py`). Sin ese fix,
la única forma real de verificar la conexión del worker era
`rabbitmqctl list_consumers` del lado del VPS.

## Prioridad de consumo

RabbitMQ entrega los mensajes de `chatbot_requests` al consumer de
mayor prioridad que esté conectado (`x-priority`, feature nativa del
broker desde RabbitMQ 3.x, sin plugin ni código custom). Este worker
usa prioridad **10**; el consumer del VPS (`techo360-infra`) quedó en
prioridad **0** como respaldo. Ver `CHATBOT_CONSUMER_PRIORITY` en
`techo360-chatbot/app/rabbitmq_consumer.py`.

## Cómo llega un mensaje del usuario a un worker (actualizado 9-oct-2026)

La sección «Hallazgo importante» de versiones anteriores (que decía que `/chatbot/send` iba directo al chatbot sin pasar por RabbitMQ) **está obsoleta**. Hoy el camino real es:

1. El frontend llama a `POST /chatbot/conversaciones/{id}/mensajes/enviar` (nginx → **backend**, no al chatbot).
2. El backend publica la petición en `chatbot_requests` como RPC (`techo360-backend/services/chatbot_rpc_client.py`, espera hasta 200 s) y persiste el intercambio él mismo.
3. RabbitMQ la entrega al consumer **de mayor prioridad que esté libre**: los workers de este repo (prioridad **10**) antes que el chatbot de la VPS (prioridad **0**), todos con `prefetch 1` (un mensaje a la vez por consumer).
4. Si todos los workers están ocupados o desconectados, el mensaje cae al Ollama de la VPS: **la VPS no es solo un último recurso**. El 9-oct, con el worker caído, atendió 8 de 10 envíos.

Sobre `POST /chatbot/send` (endpoint de pruebas locales del chatbot, sin persistencia):
- En el código del chatbot (rama `Testing`) solo existe si `CHATBOT_HABILITAR_SEND_LOCAL=1`.
- **No verificado / pendiente:** en `techo360-frontend`, `development` todavía enruta `/chatbot/send` al chatbot; el hotfix de nginx que lo responde con 405 es el PR #37 del frontend, a la espera de su autorización. No cuenta como cerrado hasta que se despliegue.

## Instalar un worker nuevo (otra máquina)

1. **Requisitos:** los de la sección «Requisitos» (Docker, `techo360-chatbot` hermano, GGUF en `models/`, credenciales de `techo360-worker`).
2. **Prioridad de consumidor = 10.** Ya es el valor por defecto (`CHATBOT_CONSUMER_PRIORITY=10` en el `.env` que genera el instalador y en el compose). No cambiarlo: con otra prioridad el reparto con la VPS (0) y entre workers deja de ser el esperado.
3. **Hilos de Ollama según las CPU de esa máquina.** Añadir al `.env` (junto a las demás variables):
   ```
   OLLAMA_NUM_THREAD=<n>
   ```
   Sin la variable queda en 3. Regla práctica: menos hilos que núcleos físicos, dejando al menos uno libre para el sistema y para el propio worker (p. ej. 4 en una máquina de 6 núcleos, 6 en una de 8). **Más hilos que núcleos libres empeora**: llama.cpp sincroniza sus hilos y uno desplazado frena a todos (medición local: con 5 hilos en un host de 6, 12,5 tok/s frente a 14,9 con 4). Medir con un mensaje real antes de dejarlo. Requiere la versión del chatbot que lee `OLLAMA_NUM_THREAD` (PR #10 de `techo360-chatbot`); con una imagen anterior la variable se ignora (queda en 3). El instalador `.exe` actual no pregunta este valor: se edita `.env` a mano y se vuelve a ejecutar `docker compose -f docker-compose.worker.yml up -d`.
4. **Política de reinicio:** `restart: unless-stopped` ya está en ambos servicios del compose. Para que el worker vuelva solo tras reiniciar la máquina, Docker Desktop debe arrancar con la sesión y la máquina debe tener red hacia RabbitMQ (Tailscale hoy). Si RabbitMQ no está disponible al arrancar, el contenedor aborta y Docker lo reintenta; una vez conectado, el consumer se reconecta solo (`connect_robust`, cada 5 s).
5. **Verificar:** `docker logs techo360-worker-chatbot` debe mostrar «Consumidor de 'chatbot_requests' arrancado (x-priority=10)», y en la VPS (solo lectura) `docker exec techo360-rabbitmq rabbitmqctl list_queues name messages consumers` debe mostrar un consumer más en `chatbot_requests`.

## Avisos de cancelación (paquete v3.3)
Cuando el usuario cancela un mensaje que el worker ya está generando, el backend publica un aviso en el exchange `chatbot_cancelaciones` y el consumer **aborta la llamada a Ollama de ese intento** (antes la generación seguía ~46 s y su resultado se descartaba). Está en el código del chatbot (`app/rabbitmq_consumer.py`, PR #11 de `techo360-chatbot`), por lo tanto **entra al worker al reconstruir la imagen desde un SHA del chatbot que lo incluya** (`build-worker-image.ps1 -ChatbotSha ...`; el `Dockerfile.worker` y `requirements-worker.txt` no cambian: usa solo `aio-pika`, `uuid` y `asyncio`).
- **Imagen vieja = sin efecto, sin daño:** ignora los campos nuevos y el exchange; sigue generando como siempre.
- **Permisos de RabbitMQ:** para suscribirse, `techo360-worker` necesita los permisos de nombres exactos del PR de `techo360-infra` (`scripts/rabbitmq-worker-user.sh`; sin `.*`, sin write en el exchange). Sin ellos el consumer arranca y trabaja igual y solo registra el aviso `No se pudo suscribir a los avisos de cancelacion` (verificado contra un RabbitMQ desechable).
- **Verificar en un worker:** `docker logs techo360-worker-chatbot | grep -i cancelacion` debe mostrar `Suscrito a los avisos de cancelacion`.
- **Límites:** un aviso que llega antes que su mensaje se recuerda 10 min y como máximo 500 avisos; la cola de avisos es exclusiva, se borra al desconectar y descarta avisos de más de 10 min. **No verificado:** que Ollama detenga su cálculo al cerrarse la conexión (probado con Ollama simulado).

## Lo que falta para el despliegue real de laboratorio (no en esta tarea)

- Reconexión automática tras apagado/encendido diario de los labs (parcial: ver «Instalar un worker nuevo», punto 4, y el PR de resiliencia de este repo; no verificado en labs reales).
- RabbitMQ escuchando en la IP privada de la universidad
  (`10.154.12.191`) -- hoy solo escucha en la IP de Tailscale.
- **Siguiente paso real antes de laboratorios**: hornear el modelo
  (`models/techo360-v3.2-Q4_K_M.gguf`) dentro de la imagen Docker del
  worker (`docker-compose.worker.yml`), para no depender de un archivo
  local en el disco de cada máquina -- hoy el instalador asume que ese
  GGUF ya está ahí (ver "Requisitos").
