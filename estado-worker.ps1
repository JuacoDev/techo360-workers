$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Output '=== contenedor ==='
docker ps -a --filter name=techo360-worker-chatbot --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
Write-Output '=== configuracion no secreta ==='
docker inspect techo360-worker-chatbot --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null |
    Where-Object { $_ -match '^(OLLAMA_MODEL|OLLAMA_URL|OLLAMA_NUM_CTX|OLLAMA_NUM_THREAD|CHATBOT_CONSUMER_PRIORITY)=' }
Write-Output '=== ultima actividad del consumer ==='
docker logs --tail 120 techo360-worker-chatbot 2>&1 |
    Select-String 'contrato_max|Consumidor de|procesar mensaje|duracion_ms|respuesta|Ollama no disponible|reconect|ERROR|WARNING' |
    Select-Object -Last 20
Write-Output '=== modelo y GPU del host ==='
ollama ps
docker exec techo360-worker-ollama ollama ps 2>$null
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader
Write-Output '=== nota RabbitMQ ==='
Write-Output 'La presencia en chatbot_requests se confirma con el log de arranque y rabbitmqctl list_consumers en el VPS; este script no imprime credenciales ni consulta el panel.'
Write-Output '=== version de Ollama (debe ser la del VPS: 0.32.6) ==='
docker exec techo360-worker-ollama ollama --version
Write-Output '=== el system se aplica? (prompt_eval_count debe ser > 100; con 0.6.8 daba 2) ==='
$prueba = @'
import json, urllib.request
msgs = [{"role": "system", "content": "Reglas: " + "Las cifras salen solo del CONTEXTO. " * 40}, {"role": "user", "content": "Hola"}]
req = urllib.request.Request('http://ollama:11434/api/chat', json.dumps({"model": "techo360-chatbot:v0.4.1", "messages": msgs, "stream": False, "options": {"num_predict": 1}}).encode(), {'Content-Type': 'application/json'})
n = json.loads(urllib.request.urlopen(req, timeout=120).read()).get('prompt_eval_count')
print('prompt_eval_count =', n, 'OK' if n and n > 100 else 'FALLA: Ollama esta descartando el system')
'@
$prueba | docker exec -i techo360-worker-chatbot python - 2>&1
