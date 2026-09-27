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
- El GGUF de producción (`techo360-chatbot/training/modelo_gguf/techo360-v3.2-Q4_K_M.gguf`)
  presente localmente -- no se distribuye por git (ver
  `techo360-chatbot/training/README.md`). En esta validación ya está
  en la máquina del desarrollador; para labs reales hace falta un
  mecanismo de distribución del modelo (fuera de alcance de esta tarea).
- Credenciales del usuario RabbitMQ `techo360-worker` (ver
  "Usuario de RabbitMQ" abajo) -- **nunca** las credenciales que ya usa
  el chatbot del VPS.

## Instalación (validación en PC propio)

```powershell
.\install-worker.ps1 -RabbitMqHost 100.116.197.118
```

Pide la contraseña del usuario `techo360-worker` de forma interactiva
(no queda en el historial de PowerShell). Ver `install-worker.ps1` para
el detalle de cada paso; en resumen: verifica Docker, construye la
imagen del worker, importa el modelo de Ollama, genera `.env`, arranca
el contenedor, y verifica en el log real que el consumer confirmó
conexión (`x-priority=10`) -- no se conforma con "container running".

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

| Permiso   | Regex                                                 | Para qué |
|-----------|--------------------------------------------------------|----------|
| configure | `^(chatbot_requests\|chatbot_eventos_persistencia)?$` | declarar/pasar por alto ambas colas |
| write     | `^(chatbot_requests\|chatbot_eventos_persistencia)?$` | publicar eventos + responder RPC por el exchange por defecto (regex vacío) |
| read      | `^chatbot_requests$`                                  | consumir la cola de solicitudes |

Se crea/actualiza con `techo360-infra/scripts/rabbitmq-worker-user.sh`,
disparado por el workflow manual `manage-rabbitmq-worker-user.yml` de
ese repo (corre `rabbitmqctl` en el contenedor real del VPS via el
runner self-hosted -- nunca SSH manual). Requiere el secret de repo
`WORKER_RABBITMQ_PASSWORD` configurado de antemano.

## Prioridad de consumo

RabbitMQ entrega los mensajes de `chatbot_requests` al consumer de
mayor prioridad que esté conectado (`x-priority`, feature nativa del
broker desde RabbitMQ 3.x, sin plugin ni código custom). Este worker
usa prioridad **10**; el consumer del VPS (`techo360-infra`) quedó en
prioridad **0** como respaldo. Ver `CHATBOT_CONSUMER_PRIORITY` en
`techo360-chatbot/app/rabbitmq_consumer.py`.

## Hallazgo importante (no resuelto en esta tarea)

`POST /chatbot/send` **no pasa por RabbitMQ hoy**: `techo360-frontend/nginx.conf`
enruta ese endpoint directo al contenedor `chatbot:8000`, que llama a
Ollama en el mismo proceso. El consumer de `chatbot_requests` (y por lo
tanto todo este pool de workers) solo recibe tráfico si algo publica en
esa cola -- hoy únicamente lo hace `techo360-chatbot/scripts/probar_rabbitmq_local.py`
(script de prueba). Para que el tráfico real de usuarios use el pool de
workers hace falta, en una tarea aparte:

1. Un publicador RPC nuevo en `techo360-backend` (mismo patrón que
   `services/proyeccion_rpc_client.py`).
2. Cambiar `techo360-frontend/nginx.conf` para que `/chatbot/send` pase
   por el backend en vez de ir directo al contenedor chatbot.

Esta tarea (validación del worker) se verificó publicando directamente
en `chatbot_requests` con el script de prueba (mismo mecanismo RPC
exacto que usaría un publicador real), no con una petición HTTP real a
`/chatbot/send`.

## Lo que falta para el despliegue real de laboratorio (no en esta tarea)

- Reconexión automática tras apagado/encendido diario de los labs.
- RabbitMQ escuchando en la IP privada de la universidad
  (`10.154.12.191`) -- hoy solo escucha en la IP de Tailscale.
- Distribución del modelo GGUF a cada máquina de laboratorio (hoy
  depende de tenerlo ya en disco).
- Empaquetar `install-worker.ps1` como `.exe` real (ej. `ps2exe`) para
  distribuir a máquinas sin PowerShell/permisos de ejecución de scripts
  -- esta primera validación corre el `.ps1` directamente.
