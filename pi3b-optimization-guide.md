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

Este e o arquivo mais importante. Crie/edite `~/.openclaw/openclaw.json`:

```json
{
  "browser": {
    "enabled": false
  },

  "canvasHost": {
    "enabled": false
  },

  "tts": {
    "auto": "off"
  },

  "discovery": {
    "mdns": {
      "mode": "off"
    },
    "wideArea": {
      "enabled": false
    }
  },

  "tools": {
    "profile": "minimal",
    "deny": [
      "browser_*",
      "image_*"
    ],
    "media": {
      "concurrency": 1,
      "video": {
        "enabled": false
      }
    },
    "web": {
      "fetch": {
        "maxChars": 10000,
        "maxCharsCap": 15000
      }
    }
  },

  "plugins": {
    "deny": [
      "open-prose",
      "matrix",
      "msteams",
      "voice-call",
      "nostr",
      "twitch",
      "feishu",
      "tlon",
      "copilot-proxy",
      "diagnostics-otel",
      "llm-task",
      "lobster",
      "memory-lancedb",
      "minimax-portal-auth",
      "qwen-portal-auth",
      "google-antigravity-auth",
      "google-gemini-cli-auth",
      "sherpa-onnx-tts",
      "skill-creator",
      "model-usage",
      "himalaya",
      "tmux",
      "video-frames",
      "nano-banana-pro",
      "coding-agent",
      "openai-image-gen",
      "openai-whisper",
      "openai-whisper-api",
      "canvas",
      "peekaboo",
      "oracle",
      "clawhub",
      "blogwatcher",
      "obsidian",
      "notion",
      "session-logs"
    ],
    "slots": {
      "memory": "none"
    }
  },

  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-20250514",
        "fallbacks": ["openai/gpt-4o-mini"]
      },
      "maxConcurrent": 1,
      "timeoutSeconds": 120,
      "mediaMaxMb": 2,
      "thinkingDefault": "off",
      "verboseDefault": "off",
      "blockStreamingDefault": "off",
      "subagents": {
        "maxConcurrent": 1
      },
      "contextPruning": {
        "mode": "cache-ttl",
        "ttl": "15m"
      },
      "compaction": {
        "mode": "safeguard",
        "reserveTokensFloor": 5000,
        "maxHistoryShare": 0.3,
        "memoryFlush": {
          "enabled": true,
          "softThresholdTokens": 2000
        }
      },
      "heartbeat": {
        "every": "60m"
      },
      "sandbox": {
        "mode": "off"
      }
    }
  },

  "models": {
    "bedrockDiscovery": {
      "enabled": false
    }
  }
}
```

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
| `thinkingDefault: "off"` | Sem "thinking" | Menos tokens/processamento |
| `compaction.mode: "safeguard"` | Compactacao agressiva | Contexto menor na RAM |
| `contextPruning.ttl: "15m"` | Limpa contexto velho | Libera RAM mais rapido |
| `sandbox.mode: "off"` | Sem Docker sandbox | Sem overhead de containers |
| `heartbeat.every: "60m"` | Heartbeat a cada hora | Menos processamento idle |

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
| **TOTAL** | **610-1020MB** | **340-470MB** |
| Swap disponivel | - | 2048MB |

Com otimizacao, sobram **~500-650MB livres** para swap e picos de uso.

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
