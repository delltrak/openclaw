# Relatório de Compatibilidade: OpenClaw em Raspberry Pi Antigo

## Resumo Executivo

O OpenClaw **pode rodar em Raspberry Pi antigo**, mas com limitações significativas
dependendo do modelo. O projeto já possui suporte oficial para ARM64 e documentação
dedicada (`docs/platforms/raspberry-pi.md`).

---

## Matriz de Compatibilidade por Modelo

| Modelo Pi         | RAM    | Arquitetura | Funciona?            | Observações                                |
| ----------------- | ------ | ----------- | -------------------- | ------------------------------------------ |
| **Pi 5 (4/8GB)**  | 4-8GB  | ARM64       | ✅ Excelente          | Recomendado, sem problemas                 |
| **Pi 4 (4GB)**    | 4GB    | ARM64       | ✅ Bom                | Ponto ideal para maioria dos usuários      |
| **Pi 4 (2GB)**    | 2GB    | ARM64       | ✅ OK                 | Precisa de swap de 2GB                     |
| **Pi 4 (1GB)**    | 1GB    | ARM64       | ⚠️ Apertado          | Possível com swap, config mínima           |
| **Pi 3B+ (2017)** | 1GB    | ARM64       | ⚠️ Lento             | Funciona mas é lento                       |
| **Pi 3B (2016)**  | 1GB    | ARM64       | ⚠️ Muito lento       | CPU quad-core 1.2GHz, pode travar          |
| **Pi 2 (2015)**   | 1GB    | ARMv7 (32b) | ❌ **Não compatível** | Não suporta Node.js 22 em 32-bit           |
| **Pi 1 (2012)**   | 512MB  | ARMv6 (32b) | ❌ **Não compatível** | RAM e arquitetura insuficientes             |
| **Pi Zero W**     | 512MB  | ARMv6 (32b) | ❌ **Não compatível** | Single-core, 32-bit, sem RAM               |
| **Pi Zero 2 W**   | 512MB  | ARM64       | ❌ Não recomendado    | RAM insuficiente (512MB)                   |

---

## Requisitos Mínimos do Projeto

Definidos no `package.json` e documentação:

| Recurso          | Mínimo                | Recomendado           |
| ---------------- | --------------------- | --------------------- |
| **Node.js**      | >= 22.12.0            | 22.x LTS             |
| **RAM**          | 1GB + swap            | 2GB+                  |
| **CPU**          | 1 core ARM64          | 4 cores ARM64         |
| **Disco**        | 500MB                 | 16GB+ (SSD via USB)   |
| **SO**           | 64-bit Linux (ARM64)  | Raspberry Pi OS Lite  |
| **Rede**         | WiFi ou Ethernet      | Ethernet (estável)    |

---

## Fatores Limitantes para Pi Antigo

### 1. Node.js 22 Requer 64-bit (ARM64/aarch64)

O requisito `"node": ">=22.12.0"` é o **maior bloqueio** para modelos antigos:

- **Pi 1, Pi 2, Pi Zero (original)**: Arquitetura ARMv6/ARMv7 (32-bit) — **Node.js 22
  não tem builds oficiais para 32-bit ARM**
- Verificar com: `uname -m` — deve mostrar `aarch64`, não `armv7l` ou `armv6l`

### 2. Dependências Nativas que Precisam Compilar

O projeto lista 9 dependências nativas em `onlyBuiltDependencies`:

| Dependência                             | ARM64 Status | Notas                                  |
| --------------------------------------- | ------------ | -------------------------------------- |
| `sharp` (processamento de imagem)       | ✅ OK        | Binários pré-compilados para ARM64     |
| `esbuild` (bundler)                     | ✅ OK        | Binários para ARM64 disponíveis        |
| `protobufjs`                            | ✅ OK        | Compila em ARM64                       |
| `@whiskeysockets/baileys` (WhatsApp)    | ✅ OK        | Maior parte é JS puro                  |
| `@lydell/node-pty` (terminal)           | ⚠️ Compilar  | Precisa de `build-essential`           |
| `@napi-rs/canvas` (canvas)              | ⚠️ Compilar  | Pode precisar de libs adicionais       |
| `@matrix-org/matrix-sdk-crypto-nodejs`  | ⚠️ Compilar  | Binding Rust, compilação pesada        |
| `authenticate-pam`                      | ⚠️ Compilar  | Binding C, precisa de headers PAM      |
| `node-llama-cpp` (LLM local)           | ❌ Evitar     | **Não rodar LLMs locais no Pi**        |

### 3. Consumo de RAM

Com 1GB de RAM (Pi 3B+), o sistema operacional já consome ~200-300MB,
deixando ~700MB para o Node.js e OpenClaw. O projeto recomenda swap de 2GB
para modelos com 2GB ou menos.

### 4. Velocidade de I/O

Modelos antigos (Pi 2, Pi 3) têm USB 2.0, o que limita a velocidade de
armazenamento externo. O SD card é ainda mais lento e se degrada com
muitas escritas.

---

## Análise por Cenário de Uso

### Cenário A: Pi 3B+ (1GB) — "O mais antigo que funciona"

- **Funciona?** Sim, com ressalvas
- **Performance:** Lenta — boot do gateway em ~30-60s, respostas mais lentas
- **Configuração necessária:**
  - Raspberry Pi OS Lite 64-bit (obrigatório)
  - Swap de 2GB
  - `gpu_mem=16` (liberar RAM)
  - Desabilitar Bluetooth, serviços desnecessários
  - Usar Ethernet (WiFi consome CPU)
- **Canais recomendados:** Telegram (leve, puro JS)
- **Evitar:** Browser automation (Playwright/Chromium), LLMs locais, muitos canais simultâneos

### Cenário B: Pi 4 (2GB) — "Ponto mínimo confortável"

- **Funciona?** Sim, bem
- **Performance:** Aceitável — gateway estável
- **Configuração necessária:**
  - Swap de 2GB
  - SSD via USB recomendado
- **Canais recomendados:** Telegram, WhatsApp, Discord
- **Evitar:** LLMs locais, muitas extensões pesadas

### Cenário C: Pi 4 (4GB) / Pi 5 — "Ideal"

- **Funciona?** Sim, sem problemas
- **Performance:** Boa — tudo roda bem
- **Todos os canais** funcionam incluindo browser automation

---

## O que FUNCIONA em ARM64 (Pi 3B+ em diante com OS 64-bit)

- ✅ Gateway WebSocket (core do projeto)
- ✅ Telegram bot (grammy — puro JS)
- ✅ WhatsApp (Baileys — puro JS)
- ✅ Discord bot (puro JS)
- ✅ Slack bot (puro JS)
- ✅ LINE bot (puro JS)
- ✅ Lark/DingTalk (puro JS)
- ✅ SQLite (database local, embutido no Node.js)
- ✅ sqlite-vec (extensão vetorial)
- ✅ sharp (processamento de imagem)
- ✅ Express HTTP server
- ✅ Systemd daemon
- ✅ Cron jobs
- ✅ Tailscale (acesso remoto)

## O que NÃO FUNCIONA / Deve ser Evitado

- ❌ LLMs locais (`node-llama-cpp`) — sem RAM/CPU suficiente
- ❌ Pi 1, Pi 2, Pi Zero (original) — arquitetura 32-bit
- ⚠️ Browser automation (Chromium) — consome muita RAM no Pi 3B+
- ⚠️ `@napi-rs/canvas` — compilação pode falhar em Pi antigo com pouca RAM
- ⚠️ Skills que dependem de binários x86 — "exec format error"

---

## Suporte Oficial do Projeto

O OpenClaw **já tem suporte oficial para Raspberry Pi**, incluindo:

1. **Documentação dedicada**: `docs/platforms/raspberry-pi.md`
2. **Docker multi-platform**: Builds ARM64 no CI (`docker-release.yml`)
3. **Workaround para ARM**: `OPENCLAW_PREFER_PNPM=1` no Dockerfile (Bun pode falhar em ARM)
4. **Tabela de compatibilidade** mantida pela equipe
5. **Guia de otimização** para baixo consumo de recursos

---

## Conclusão

| Pergunta                                          | Resposta                                                   |
| ------------------------------------------------- | ---------------------------------------------------------- |
| Roda em Pi antigo?                                | **Pi 3B+ (64-bit) sim, Pi 2 e anteriores não**            |
| Qual o Pi mais antigo que funciona?               | **Pi 3B+ com Raspberry Pi OS 64-bit + swap**              |
| Precisa de muito recurso?                         | **Não — é gateway, os modelos de IA rodam na nuvem**      |
| Precisa de internet?                              | **Sim — para APIs de IA (Claude, OpenAI, etc.)**          |
| Compensa vs VPS na nuvem?                         | **Pi se paga em 6-12 meses vs $6/mês de VPS**            |
| Docker funciona no Pi?                            | **Sim — images ARM64 oficiais no ghcr.io**                |
