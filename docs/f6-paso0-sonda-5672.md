# F6 paso 0 — sonda temporal en 10.154.12.191:5672 (NO EJECUTAR sin «autorizo paso F6-0»)

Objetivo: comprobar, **sin tocar RabbitMQ, el compose ni `techo360-infra`**, que `10.154.12.191` es una
dirección de una interfaz de la VPS (el contenedor puede enlazarla) y que un PC del laboratorio llega
a ese puerto. Todo por SSH (puerto 22), solo con autorización de fase. Nada de esto se ha ejecutado.

## 1. Solo lectura (antes de crear nada)

```bash
ip -br addr | grep -F 10.154.12.191 || echo "NO ES UNA IP DE LA VPS -> parar y reportar"
ss -ltn | grep ':5672'                       # no debe haber un listener 0.0.0.0:5672 ni 10.154.12.191:5672
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '5672'   # el RabbitMQ real publica SOLO en la IP Tailscale
docker images --format '{{.Repository}}:{{.Tag}}' | grep -F 'rabbitmq:3.13-management-alpine'   # imagen ya presente (no se descarga nada)
# si no aparece, usar otra imagen con busybox ya presente (p. ej. postgres:16-alpine); NO descargar nada
```

Si `ip -br addr` no muestra la IP: **parar** (NAT / IP flotante en el firewall): publicar con ese bind haría
fallar el contenedor y, aplicado al compose real, tumbaría RabbitMQ.

## 2. Contenedor temporal (se borra solo; ≤ 10 min)

Usa una imagen que **ya existe** en la VPS (busybox viene dentro de la imagen alpine de RabbitMQ; no se
descarga nada ni se ejecuta RabbitMQ). Límites de memoria/CPU mínimos, sin volúmenes, red por defecto.

```bash
docker run -d --rm --name t360-sonda-5672 \
  --memory 16m --cpus 0.1 --pids-limit 32 \
  -p 10.154.12.191:5672:9000 \
  --entrypoint sh rabbitmq:3.13-management-alpine \
  -c 'timeout 600 nc -lk -p 9000 -e /bin/true'
```

- Si Docker responde `cannot assign requested address` (o similar) → **no es una interfaz de la VPS**:
  parar, confirmar con `docker ps -a --filter name=t360-sonda-5672` que no quedó nada y reportar.
- Avisar a Juan para que pruebe desde un PC del laboratorio:
  `Test-NetConnection 10.154.12.191 -Port 5672` (`TcpTestSucceeded : True`). La sonda acepta y cierra; **no** habla AMQP.
- Resultado esperado y significado:
  - `True` → la ruta existe: no hace falta solicitar nada al CCA/CTIC.
  - **timeout** → el puerto no está abierto desde esa red: redactar la solicitud (abajo).

## 3. Limpieza y confirmación (siempre)

```bash
docker rm -f t360-sonda-5672 2>/dev/null
docker ps -a --filter name=t360-sonda-5672 --format '{{.Names}}' | wc -l    # debe ser 0
ss -ltn | grep -F '10.154.12.191:5672' | wc -l                              # debe ser 0
```

El contenedor tiene `--rm` y `timeout 600`, así que desaparece solo aunque se olvide la limpieza.

## 4. Solicitud al CCA/CTIC (solo si la prueba desde el laboratorio da timeout)

> **Asunto:** Apertura de 5672/TCP hacia el servidor de Techo 360
> **Origen:** redes de los laboratorios `<rangos a confirmar por CTIC>`.
> **Destino:** `10.154.12.191`, puerto `5672/TCP` (AMQP).
> **Motivo:** los equipos del laboratorio ejecutan *workers* de inferencia del chatbot de Techo 360 que consumen
> una cola de RabbitMQ del servidor; sin este puerto no pueden conectarse.
> **Alcance:** solo 5672/TCP. **No** se solicita el 15672 (panel de administración), que permanece restringido a la
> red privada de gestión. Autenticación por usuario dedicado con permisos mínimos.
> **Nota:** el tráfico AMQP viaja sin TLS en esta etapa (pendiente de mejora).

## 5. Después (otra autorización, «autorizo paso F6»)

Diff de `techo360-infra/docker-compose.yml`: **añadir** `10.154.12.191:5672:5672` manteniendo
`100.116.197.118:5672:5672`; el 15672 no se modifica (el compose ya lo publica solo en la IP Tailscale).
`deploy-infra` recrea solo `rabbitmq`; los consumers se reconectan (ver T-127 y el bug de reconexión documentado).
