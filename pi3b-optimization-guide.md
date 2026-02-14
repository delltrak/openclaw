# Guia de Otimizacao: OpenClaw no Raspberry Pi 3B+ (1GB RAM)

## Diagnostico do Problema

O Pi 3B+ tem **1GB de RAM** e um CPU quad-core 1.4GHz. O OpenClaw carrega:
- 35 extensoes (channels, integracao, etc.)
- 51 skills (ferramentas para o agente)
- Subsistemas pesados: browser automation, media processing, TTS, PDF, Canvas
- Dependencias nativas: sharp, playwright-core, @aws-sdk/client-bedrock

Sem otimizacao, facilmente ultrapassa 600-800MB de RAM so com o Node.js.

---

## PARTE 1: Otimizacoes no Sistema Operacional

### 1.1 Swap obrigatorio (2GB)

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 1.2 Liberar RAM da GPU (headless)

```bash
echo 'gpu_mem=16' | sudo tee -a /boot/config.txt
```

### 1.3 Desabilitar servicos desnecessarios

```bash
sudo systemctl disable --now bluetooth
sudo systemctl disable --now cups
sudo systemctl disable --now avahi-daemon
sudo systemctl disable --now triggerhappy
sudo systemctl disable --now ModemManager 2>/dev/null
```

### 1.4 WiFi power management off (se usar WiFi)

```bash
sudo iwconfig wlan0 power off
echo 'wireless-power off' | sudo tee -a /etc/network/interfaces
```

---

## PARTE 2: Configuracao do Node.js

### 2.1 Limitar heap do V8

No arquivo de servico systemd ou no shell:

```bash
export NODE_OPTIONS="--max-old-space-size=384"
```

Isso limita o heap do V8 a 384MB, forcando garbage collection mais agressivo.

### 2.2 Usar Module Compile Cache (ja habilitado)

O OpenClaw ja usa `Module.enableCompileCache()` no entry point - isso ajuda.

---

## PARTE 3: Configuracao do OpenClaw (openclaw.json)

Este e o arquivo mais importante. Use o `pi3b-openclaw-config.json` fornecido,
ou crie/edite `~/.openclaw/openclaw.json` com o conteudo desse arquivo.

Pontos-chave da configuracao:

- **Thinking: "low"** - raciocinio basico mantido (processado na API, 0 RAM local)
- **Memoria vetorial: habilitada** - embeddings via OpenAI API (0 RAM para modelo)
- **SQLite + sqlite-vec** - armazenamento local leve (~30-80MB)
- **Browser/Canvas/TTS** - desabilitados (economia de ~150-250MB)
- **27 extensoes pesadas** - bloqueadas via deny list
- **Sandbox Docker** - desabilitado

---

## PARTE 4: Variaveis de Ambiente

Crie o arquivo `~/.openclaw/.env` ou configure no systemd:

```bash
# Desabilitar subsistemas pesados
OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
OPENCLAW_SKIP_CANVAS_HOST=1
OPENCLAW_SKIP_GMAIL_WATCHER=1
OPENCLAW_SKIP_CRON=1
OPENCLAW_DISABLE_BONJOUR=1

# Limitar heap do Node.js
NODE_OPTIONS=--max-old-space-size=384

# API key para embeddings remotos (memoria vetorial)
# Escolha UMA das opcoes:
OPENAI_API_KEY=sk-sua-chave-aqui
# OU para Gemini (gratis):
# GOOGLE_API_KEY=sua-chave-gemini
```

---

## PARTE 5: Systemd Service Otimizado

Crie `/etc/systemd/system/openclaw.service`:

```ini
[Unit]
Description=OpenClaw Gateway (Pi 3B+ Optimized)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi

# Limites de recurso
MemoryMax=512M
MemoryHigh=400M
CPUQuota=80%
LimitNOFILE=4096
LimitNPROC=128

# Variaveis de ambiente
Environment=NODE_OPTIONS=--max-old-space-size=384
Environment=OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
Environment=OPENCLAW_SKIP_CANVAS_HOST=1
Environment=OPENCLAW_SKIP_GMAIL_WATCHER=1
Environment=OPENCLAW_SKIP_CRON=1
Environment=OPENCLAW_DISABLE_BONJOUR=1
Environment=NODE_ENV=production

ExecStart=/usr/bin/node /home/pi/openclaw/openclaw.mjs gateway --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable openclaw
sudo systemctl start openclaw
```

---

## PARTE 6: O que cada otimizacao economiza

### Subsistemas desabilitados

| Subsistema | Env var / Config | RAM economizada |
|---|---|---|
| Browser Control (Playwright) | `OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1` | ~80-150MB |
| Canvas Host | `OPENCLAW_SKIP_CANVAS_HOST=1` | ~20-40MB |
| Gmail Watcher | `OPENCLAW_SKIP_GMAIL_WATCHER=1` | ~10-20MB |
| Cron Scheduler | `OPENCLAW_SKIP_CRON=1` | ~5-10MB |
| Bonjour/mDNS | `OPENCLAW_DISABLE_BONJOUR=1` | ~5-10MB |
| TTS (Text-to-Speech) | `tts.auto: "off"` | ~10-20MB |
| Bedrock Discovery | `models.bedrockDiscovery.enabled: false` | ~30-50MB (AWS SDK) |
| Sandbox/Docker | `sandbox.mode: "off"` | ~20-40MB |

### Extensoes desabilitadas (35 -> ~8 ativas)

| Extensao removida | Motivo | RAM economizada |
|---|---|---|
| `open-prose` | ML models embarcados (ONNX) | ~50-100MB |
| `matrix` | Crypto nativo (Rust binding) | ~30-50MB |
| `msteams` | Stack Microsoft pesado | ~20-30MB |
| `voice-call` | Audio real-time WebSocket | ~20-30MB |
| `memory-lancedb` | Vector DB alternativo | ~20-30MB |
| 22 outras extensoes | Nao necessarias no Pi | ~50-80MB |

### Skills desabilitadas (51 -> ~15 ativas)

| Skill removida | Motivo |
|---|---|
| `sherpa-onnx-tts` | Requer runtime ONNX de 100MB+ |
| `coding-agent` | Inferencia LLM pesada |
| `video-frames` | Requer FFmpeg + processamento pesado |
| `openai-image-gen` | Processamento de imagem |
| `openai-whisper*` | Transcricao de audio |
| `canvas` | Renderizacao grafica |
| 10+ outras | Funcionalidade desnecessaria no Pi |

### Configuracoes de agente

| Config | Valor | Efeito |
|---|---|---|
| `maxConcurrent: 1` | 1 agente por vez | Evita picos de RAM |
| `subagents.maxConcurrent: 1` | 1 sub-agente | Evita picos de RAM |
| `thinkingDefault: "low"` | Thinking leve | Raciocinio basico sem explodir tokens |
| `compaction.mode: "safeguard"` | Compactacao agressiva | Contexto menor na RAM |
| `contextPruning.ttl: "15m"` | Limpa contexto velho | Libera RAM mais rapido |
| `sandbox.mode: "off"` | Sem Docker sandbox | Sem overhead de containers |
| `heartbeat.every: "60m"` | Heartbeat a cada hora | Menos processamento idle |

---

## PARTE 6.1: Thinking (Raciocinio) - Mantido e Otimizado

O thinking permite que o modelo "pense" antes de responder. Niveis disponiveis:
`off < minimal < low < medium < high < xhigh`

**Configuracao escolhida: `"low"`**

Motivo: `low` oferece raciocinio basico (planejamento de resposta, verificacao
de fatos na memoria) sem consumir muitos tokens extras. O custo de RAM no Pi
e zero - o thinking acontece no servidor da API (Anthropic/OpenAI), nao localmente.

O impacto real e:
- **Latencia**: +1-3 segundos por resposta (aceitavel)
- **Custo de API**: ~20-40% mais tokens por resposta
- **RAM local**: 0 MB extra (processado no servidor remoto)

Se quiser mais raciocinio, pode subir para `"medium"` sem impacto na RAM local.
Use `/think medium` ou `/think high` em tempo real durante a conversa.

---

## PARTE 6.2: Memoria Vetorial - Estrategia "Remote Embeddings"

### O problema do embedding local

O provider `"local"` usa `node-llama-cpp` com um modelo GGUF de 300M parametros.
Isso consome **500-900MB de RAM** - impossivel no Pi 3B+ com 1GB.

### A solucao: embeddings via API remota (OpenAI)

Em vez de rodar o modelo de embeddings localmente, usamos a API da OpenAI
(`text-embedding-3-small`) para gerar os vetores. O Pi so armazena os resultados
no SQLite local.

**Fluxo:**
```
Usuario fala algo → OpenClaw salva no MEMORY.md
                   → Envia texto para OpenAI API (embedding)
                   → Recebe vetor de 1536 dimensoes
                   → Armazena no SQLite local (sqlite-vec)

Usuario pergunta  → OpenClaw gera embedding da pergunta (API)
                   → Busca vetores similares no SQLite local
                   → Retorna contexto relevante para o modelo
```

**Custo:** ~$0.02 por milhao de tokens (praticamente gratis)

**RAM local:** ~30-80MB (SQLite + cache de 1000 embeddings)

### Configuracao da memoria (ja no pi3b-openclaw-config.json)

```json
"memorySearch": {
  "enabled": true,
  "provider": "openai",
  "model": "text-embedding-3-small",
  "sources": ["memory"],
  "chunking": {
    "tokens": 200,
    "overlap": 40
  },
  "sync": {
    "onSessionStart": true,
    "onSearch": true,
    "watch": false,
    "intervalMinutes": 0
  },
  "query": {
    "maxResults": 3,
    "minScore": 0.4,
    "hybrid": {
      "enabled": true,
      "vectorWeight": 0.6,
      "textWeight": 0.4,
      "candidateMultiplier": 2
    }
  },
  "store": {
    "driver": "sqlite",
    "vector": { "enabled": true },
    "cache": { "enabled": true, "maxEntries": 1000 }
  }
}
```

### O que cada parametro faz

| Parametro | Valor | Por que |
|---|---|---|
| `provider: "openai"` | API remota | 0 MB de RAM para embeddings |
| `model: "text-embedding-3-small"` | Modelo menor | Mais rapido e barato |
| `sources: ["memory"]` | So pasta memory/ | Nao indexa sessoes (economiza disco e RAM) |
| `chunking.tokens: 200` | Chunks menores | Menos embeddings por documento |
| `chunking.overlap: 40` | Overlap menor | Menos redundancia |
| `sync.watch: false` | Sem file watcher | Economiza CPU/RAM do inotify |
| `sync.intervalMinutes: 0` | Sem sync periodico | Sync so quando precisa |
| `query.maxResults: 3` | 3 resultados max | Menos dados na RAM por busca |
| `query.minScore: 0.4` | Threshold alto | Resultados mais relevantes |
| `query.hybrid.candidateMultiplier: 2` | Pool menor | Menos calculos de similaridade |
| `store.cache.maxEntries: 1000` | Cache limitado | ~10-20MB max de cache |

### Variavel de ambiente necessaria

```bash
export OPENAI_API_KEY=sk-sua-chave-aqui
```

Adicione no `~/.openclaw/.env` ou no systemd service.

### Alternativa sem custo: Gemini embeddings (gratis)

Se nao quiser pagar pela API da OpenAI, o Google Gemini oferece
embeddings gratuitos com limite generoso:

```json
"memorySearch": {
  "provider": "gemini",
  "model": "gemini-embedding-001"
}
```

```bash
export GOOGLE_API_KEY=sua-chave-gemini
```

---

## PARTE 7: Quais canais manter

Para 1GB de RAM, recomendo **1 canal ativo**:

### Opcao A: So Telegram (mais leve)
```json
{
  "plugins": {
    "allow": ["telegram", "device-pair"]
  }
}
```
- grammy e puro JS, muito leve
- Sem WebSocket persistente pesado
- **Estimativa: ~100-150MB total**

### Opcao B: So WhatsApp (mais pesado)
```json
{
  "plugins": {
    "allow": ["whatsapp", "device-pair"]
  }
}
```
- Baileys usa WebSocket persistente
- Precisa manter conexao ativa
- **Estimativa: ~150-200MB total**

### Opcao C: Telegram + WhatsApp (no limite)
```json
{
  "plugins": {
    "allow": ["telegram", "whatsapp", "device-pair"]
  }
}
```
- **Estimativa: ~200-280MB total**
- Funciona, mas sem margem para picos

---

## PARTE 8: Estimativa de RAM final

| Componente | RAM sem otimizacao | RAM otimizado |
|---|---|---|
| Linux + overhead | 200-300MB | 150-200MB |
| Node.js runtime | 80-120MB | 60-80MB |
| Gateway core | 100-150MB | 80-100MB |
| Extensoes/plugins | 200-400MB | 20-40MB |
| Canal (1x Telegram) | 30-50MB | 30-50MB |
| Memoria vetorial (SQLite+cache) | 500-900MB (local) | 30-80MB (remoto) |
| Thinking | 0MB (API) | 0MB (API) |
| **TOTAL** | **1110-1920MB** | **370-550MB** |
| Swap disponivel | - | 2048MB |

Com otimizacao, sobram **~450-630MB livres** + 2GB swap para picos.
O thinking e os embeddings rodam no servidor remoto, custo de RAM local e minimo.

---

## PARTE 9: Monitoramento

```bash
# RAM em tempo real
watch -n 5 free -h

# Processos por RAM
ps aux --sort=-%mem | head -10

# Temperatura da CPU
vcgencmd measure_temp

# Throttling (deve ser 0x0)
vcgencmd get_throttled

# Logs do OpenClaw
journalctl -u openclaw -f --no-pager

# Uso de RAM do Node.js especifico
ps -p $(pgrep -f "openclaw.mjs") -o pid,rss,vsz,%mem,%cpu
```

---

## PARTE 10: Se ainda nao for suficiente

Se depois de todas as otimizacoes ainda tiver problemas:

1. **Usar Docker no Pi** com limite de memoria:
   ```bash
   docker run --memory=400m --memory-swap=800m ghcr.io/openclaw/openclaw:latest
   ```

2. **Desabilitar TODOS os canais** e usar so API direta:
   ```bash
   OPENCLAW_SKIP_CHANNELS=1 openclaw gateway
   ```
   Acesse via WebSocket na porta 18789 de outro dispositivo.

3. **Considerar upgrade**: Pi 4 (2GB) custa ~R$200 e dobra os recursos.
