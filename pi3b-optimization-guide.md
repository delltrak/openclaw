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
Environment=Environment=OPENCLAW_DISABLE_BONJOUR=1
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
| Cron Scheduler | habilitado (lembretes) | 0MB (mantido) |
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

---

## PARTE 11: Nivel de Autonomia - Pi vs Original

### O que e "AGI-like" no OpenClaw

O OpenClaw tem um sistema de autonomia em camadas:

1. **Thinking** - raciocinio interno do modelo (chain-of-thought)
2. **Tool use** - invocacao de ferramentas (exec, fs, web, messaging)
3. **Sub-agents** - criar outros agentes para tarefas paralelas
4. **Heartbeat** - agir proativamente sem input do usuario
5. **Hooks** - reagir a eventos automaticamente
6. **Elevated mode** - escalar permissoes para acesso total ao host
7. **Cron** - agendar tarefas futuras autonomamente

### Perfis de ferramentas (o que cada um libera)

```
minimal    → session_status (so olha status)
messaging  → enviar/receber mensagens, historico, listar sessoes
coding     → ler/escrever arquivos, executar comandos, sub-agentes, memoria
full       → TUDO: browser, exec, cron, nodes, web, fs, elevated
```

### Comparacao Pi (otimizado) vs Original (full)

Perfil usado: `coding` + `group:messaging` + `group:web` (mesclagem coding+messaging)

| Capacidade | Pi (coding+messaging) | Original (full) |
|---|---|---|
| Raciocinio/thinking | low (~70%) | xhigh (100%) |
| Memoria longo prazo | 100% (remoto) | 100% |
| Enviar/receber mensagens | 100% | 100% |
| Busca web | 100% | 100% |
| Busca na memoria vetorial | 100% | 100% |
| Historico de sessoes | 100% | 100% |
| Sub-agentes (sessions_spawn) | 100% (1 por vez) | 100% (N por vez) |
| Ler/escrever arquivos (fs) | 100% | 100% |
| Executar comandos (exec) | 100% | 100% |
| Processos (process) | 100% | 100% |
| Gerar imagens (image) | 100% | 100% |
| Controle de browser | desabilitado | 100% |
| Agendar tarefas (cron) | 100% | 100% |
| Controle de devices (nodes) | desabilitado | 100% |
| Modo elevado | desabilitado | 100% |
| **Autonomia total** | **~90%** | **100%** |

### Onde esta a "inteligencia" real

A inteligencia do OpenClaw vem de 3 coisas:

1. **O modelo LLM** (Anthropic/OpenAI) - processado remotamente, 100% preservado
2. **Thinking tokens** - raciocinio estendido, preservado em nivel "low"
3. **Memoria vetorial** - lembrar do usuario, 100% preservado via API remota

Nenhuma dessas 3 roda no Pi. O Pi e apenas o "corpo" - recebe mensagens,
encaminha para a API, armazena memoria. O "cerebro" esta na nuvem.

### O que a mesclagem coding+messaging da

A config usa `coding` como base e adiciona `group:messaging` + `group:web`:

```
coding base:  read, write, edit, apply_patch, exec, process,
              sessions_list/history/send/spawn, session_status,
              memory_search, memory_get, image

+ messaging:  message (enviar para canais)
+ web:        web_search, web_fetch

+ cron:       cron (agendar lembretes e tarefas)

- deny:       browser, canvas, nodes (pesados ou desnecessarios)
```

Resultado: o agente pode conversar, lembrar, buscar na web, ler/escrever
arquivos, executar comandos, agendar lembretes e criar sub-agentes.
So nao controla browser ou gerencia devices externos.

### Para subir para autonomia total (sem custo de RAM)

```json
"profile": "full"
```

Isso libera browser, nodes e elevated mode. O custo de RAM e
praticamente zero - a diferenca e so quais ferramentas o modelo pode
invocar. Mas browser precisa de `browser.enabled: true` e consome
~150MB extra de RAM.

### Conclusao

A versao Pi preserva **~90% da autonomia** e **100% da inteligencia**.
O que perdemos sao browser automation e device control.
Para um assistente que conversa, lembra, busca na web, le/escreve
arquivos, executa comandos e agenda lembretes, e praticamente a
mesma experiencia do full.

---

## PARTE 12: Imagem Customizada - DietPi (recomendado)

### Por que trocar o OS?

O Raspberry Pi OS Lite consome ~200 MB de RAM so pro sistema idle.
Com DietPi, o idle cai para ~50 MB, liberando +150 MB para o OpenClaw.

### Comparacao de OS para Pi 3B+

| OS | RAM idle | RAM livre pro OpenClaw | Dificuldade |
|---|---|---|---|
| Pi OS Lite (padrao) | ~200 MB | 726 MB | Facil |
| Pi OS Lite (stripped) | ~130 MB | 796 MB | Facil |
| **DietPi** (recomendado) | **~50 MB** | **876 MB** | Facil |
| Alpine Linux | ~50 MB | 876 MB | Medio |
| Buildroot | ~25 MB | 901 MB | Dificil |

### Por que DietPi e nao Alpine?

- **glibc**: todas as dependencias nativas (sharp, node-pty, sqlite-vec)
  funcionam sem recompilar. Alpine usa musl que pode dar problemas
- **Familiar**: baseado em Debian, usa `apt install`
- **Otimizado para SBCs**: RAMlog, CPU governor, dietpi-software
- **RAM praticamente igual**: ~50 MB vs ~50 MB do Alpine
- **Comunidade ativa**: suporte direto para Pi 3B+

### O que o DietPi remove vs Pi OS Lite

| Componente removido | RAM economizada |
|---|---|
| systemd-journald (usa RAMlog) | ~10-15 MB |
| avahi-daemon | ~5-10 MB |
| rsyslog | ~5-10 MB |
| triggerhappy | ~2-5 MB |
| dbus (minimo) | ~5-10 MB |
| Bluetooth stack (bluez) | ~5-10 MB |
| Audio (ALSA/Pulse) | ~5-10 MB |
| Kernel modules extras | ~10-20 MB |
| **Total economizado** | **~50-90 MB** |

Adicionalmente usa Dropbear no lugar de OpenSSH (economiza ~5 MB).

### Como usar a imagem customizada

Opcao A - Build automatizado:
```bash
bash scripts/build-dietpi-image.sh
# Gera: build/dietpi-openclaw-pi3b.img
sudo dd if=build/dietpi-openclaw-pi3b.img of=/dev/sdX bs=4M status=progress
```

Opcao B - Instalacao manual no DietPi:
```bash
# 1. Baixe DietPi ARMv8: https://dietpi.com/#download
# 2. Flash no SD card com balenaEtcher
# 3. Boot e aguarde setup automatico (~5 min)
# 4. SSH: ssh root@DietPi (senha: dietpi)
# 5. Instale Node.js:
dietpi-software install 9  # Node.js
# 6. Instale OpenClaw:
npm install -g pnpm
git clone https://github.com/nicholasgriffintn/openclaw.git /opt/openclaw
cd /opt/openclaw && pnpm install
# 7. Copie a config otimizada:
mkdir -p ~/.openclaw
cp pi3b-openclaw-config.json ~/.openclaw/openclaw.json
# 8. Configure API key:
echo 'OPENAI_API_KEY=sk-sua-chave' >> ~/.openclaw/.env
# 9. Rode o setup:
bash scripts/pi3b-setup.sh
```

### Bonus: zram swap (melhor que swapfile no SD card)

O DietPi suporta zram nativamente. Em vez de swap em arquivo
(que desgasta o SD card), usamos swap comprimida na RAM:

```bash
# 2 GB de swap comprimida usando ~200 MB de RAM real
modprobe zram
zramctl /dev/zram0 --size 2G --algorithm lz4
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```

Vantagens: mais rapido que SD card, sem desgaste do cartao,
e a compressao lz4 e tao rapida que nao impacta a CPU.

### RAM final com DietPi

| Componente | Pi OS Lite | DietPi |
|---|---|---|
| OS idle | 200 MB | **50 MB** |
| OpenClaw otimizado | 285 MB | 285 MB |
| **Total usado** | **485 MB** | **335 MB** |
| **RAM livre** | **441 MB (48%)** | **591 MB (64%)** |
| Swap (zram) | 2 GB (arquivo) | 2 GB (comprimido) |

Com DietPi, o Pi 3B+ fica com **64% de RAM livre** - sobra muito
espaco para picos de uso, e o zram protege o SD card.

---

## PARTE 13: Instalacao Completa (do zero)

### Opcao 1: Script automatico (recomendado)

No Pi 3B+ com DietPi ou Pi OS Lite ja instalado:

```bash
# Baixar e executar o instalador
curl -fsSL https://raw.githubusercontent.com/.../scripts/pi3b-install.sh | bash

# OU se ja tiver o repo clonado:
bash scripts/pi3b-install.sh
```

O script faz tudo automaticamente:
1. Verifica arquitetura (aarch64) e RAM
2. Configura swap (zram ou arquivo)
3. Reduz GPU para 16MB
4. Desabilita servicos desnecessarios
5. Instala Node.js 22, pnpm, build-essential
6. Clona OpenClaw e faz build (pnpm install + pnpm build)
7. Instala config otimizada para Pi
8. Cria servico systemd
9. Instala comando `openclaw-update`

### Opcao 2: Instalacao manual passo a passo

```bash
# 1. Instalar dependencias do sistema
sudo apt-get update
sudo apt-get install -y build-essential python3 git curl

# 2. Instalar Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 3. Instalar pnpm
npm install -g pnpm

# 4. Clonar OpenClaw
git clone --depth 1 https://github.com/nicholasgriffintn/openclaw.git /opt/openclaw
cd /opt/openclaw

# 5. Instalar dependencias e fazer build
pnpm install
pnpm build

# 6. (Opcional) Build da interface web
pnpm ui:build

# 7. Configurar
mkdir -p ~/.openclaw
cp pi3b-openclaw-config.json ~/.openclaw/openclaw.json

# 8. Configurar API keys
cat > ~/.openclaw/.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-sua-chave
OPENAI_API_KEY=sk-sua-chave
OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
OPENCLAW_SKIP_CANVAS_HOST=1
OPENCLAW_SKIP_GMAIL_WATCHER=1
OPENCLAW_DISABLE_BONJOUR=1
NODE_OPTIONS=--max-old-space-size=384
EOF

# 9. Testar (foreground)
node openclaw.mjs gateway --allow-unconfigured --verbose

# 10. Instalar como servico
bash scripts/pi3b-setup.sh
sudo systemctl start openclaw
```

### Opcao 3: Com variaveis de ambiente pre-definidas

```bash
ANTHROPIC_API_KEY=sk-ant-xxx \
OPENAI_API_KEY=sk-xxx \
OPENCLAW_BRANCH=main \
bash scripts/pi3b-install.sh
```

As API keys sao automaticamente escritas no .env.

---

## PARTE 14: Sistema de Atualizacao

### Comando de atualizacao

Apos a instalacao, o comando `openclaw-update` fica disponivel:

```bash
# Verificar se ha atualizacoes
openclaw-update --check

# Atualizar para a versao mais recente
openclaw-update

# Trocar de branch
openclaw-update --branch develop

# Voltar para a versao anterior (se algo quebrar)
openclaw-update --rollback
```

### O que o updater faz automaticamente

1. **Busca mudancas** no repositorio remoto
2. **Salva ponto de rollback** (commit atual)
3. **Puxa os commits** novos
4. **Detecta o que mudou**:
   - `package.json` / `pnpm-lock.yaml` → reinstala dependencias
   - `src/` / `tsdown.config` → reconstroi TypeScript
   - `ui/` → reconstroi interface web
   - `pi3b-openclaw-config.json` → avisa sobre mudanca de config
5. **Reinicia o servico** (so se necessario)
6. **Verifica se iniciou** - se falhar, faz rollback automatico

### Atualizacao automatica (cron)

Para atualizar toda noite as 3h da manha:

```bash
# Adicionar ao crontab
crontab -e
```

Adicione a linha:
```
0 3 * * * /usr/local/bin/openclaw-update --auto >> /var/log/openclaw-update.log 2>&1
```

O modo `--auto` nao aplica mudancas de config automaticamente
(voce precisa revisar manualmente). Mas reinstala deps e reconstroi
se necessario.

### Rollback

Se algo der errado apos uma atualizacao:

```bash
# Voltar para a ultima versao que funcionava
openclaw-update --rollback

# Ver qual versao esta rodando
cd /opt/openclaw && git log --oneline -5
```

O rollback:
1. Volta para o commit salvo antes da atualizacao
2. Reinstala dependencias daquele commit
3. Reconstroi o projeto
4. Reinicia o servico

### Fluxo de desenvolvimento → Pi

```
Voce (dev machine)           Pi 3B+ (producao)
─────────────────            ──────────────────
git commit + push    ──→     openclaw-update
                             ├─ git pull
                             ├─ pnpm install (se deps mudaram)
                             ├─ pnpm build (se src mudou)
                             ├─ systemctl restart openclaw
                             └─ verificacao de saude
```

### Estrutura de arquivos no Pi

```
/opt/openclaw/                    # Codigo-fonte + build
├── openclaw.mjs                  # Entry point
├── dist/                         # Build compilado
├── node_modules/                 # Dependencias
├── pi3b-openclaw-config.json     # Template de config
├── scripts/
│   ├── pi3b-install.sh           # Instalador
│   ├── pi3b-update.sh            # Atualizador
│   └── pi3b-setup.sh             # Setup de sistema
└── ...

~/.openclaw/                      # Dados do usuario
├── openclaw.json                 # Config ativa
├── .env                          # API keys e env vars
├── .last-good-commit             # Ponto de rollback
└── state/                        # Sessoes, memoria, etc.

/etc/systemd/system/
└── openclaw.service              # Servico systemd

/usr/local/bin/
└── openclaw-update -> /opt/openclaw/scripts/pi3b-update.sh
```
