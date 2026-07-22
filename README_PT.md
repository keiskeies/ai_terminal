<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>Controle seus servidores com linguagem natural. A IA executa os comandos para você.</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top" target="_blank">🌐 Site</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/releases" target="_blank">📦 Download</a> ·
    <a href="./QUESTION.md">❓ FAQ</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Platform" />
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License" />
    <img src="https://img.shields.io/badge/version-1.3.6-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**🌍 Idioma:**
[中文](./README.md) | [English](./README_EN.md) | [日本語](./README_JA.md) | [Deutsch](./README_DE.md) | [Français](./README_FR.md) | [Español](./README_ES.md) | [한국어](./README_KO.md) | [Русский](./README_RU.md) | **Português** | [Italiano](./README_IT.md)

---

## Uma frase para explicar

> **Nunca usou um terminal? Não tem problema.** Abra o AI Terminal, diga o que deseja em linguagem simples — ele se conecta ao seu servidor, executa comandos, instala softwares e resolve problemas. Tudo seguro e sob seu controle.

## 🎯 Soa familiar?

### 😫 Iniciantes / Usuários não técnicos

- Você alugou um VPS, abriu o terminal e ficou olhando para uma **tela preta** sem saber o que digitar
- Um amigo disse "é só instalar o Nginx" — você pesquisou 10 tutoriais, cada um com comandos diferentes
- Tentou configurar o Java, editou o `PATH` errado e quebrou todo o seu terminal
- Alguém avisou sobre uma vulnerabilidade no servidor — você nem sabe como verificar
- Depois de 3 horas tentando, nada funciona. Você desiste.

### 👨‍💻 Desenvolvedores

- Você pesquisa os mesmos comandos `chmod` / `systemctl` todas as vezes
- Conecta por SSH em um servidor e esquece as flags exatas do `grep` que precisa
- Quer verificar logs? Primeiro, encontre aquele favorito de 6 meses atrás
- 15 abas do navegador abertas, alternando entre servidores, perdendo o controle do que está onde

### 🔧 DevOps / Administradores de sistema

- Mesmo software em 10 servidores? Conecte por SSH em cada um e repita. De novo.
- "Quem mudou essa configuração?" — ninguém lembra, nada é registrado
- Novo funcionário pergunta "como configuro o ambiente?" — você já explicou isso 5 vezes este mês
- Quer fazer uma verificação de saúde em lote? Escrever o script demora mais do que fazer manualmente

### 🧑‍💼 Gerentes de produto / Fundadores solo

- Seu único desenvolvedor saiu. O servidor agora é uma caixa preta.
- Você precisa verificar alguns dados mas não sabe escrever SQL. Tem que pedir a alguém.
- Implantar uma mudança de configuração requer um sprint de desenvolvimento. É literalmente uma linha.
- Você usa 5 chapéus. Não tem tempo para aprender `vi`.

**Todos os cenários acima? Uma frase para o AI Terminal resolve.**

## 🆕 Novidades na v1.3.6

A v1.3.6 é uma atualização importante com **5 novas funcionalidades principais**: Monitoramento do servidor, Registro de alterações, Runbooks Ops, Central de notificações e UI de glassmorfismo — uma atualização completa para a eficiência de DevOps.

### 📊 Painel de Monitoramento do Servidor em Tempo Real

> Não precisa mais digitar `top`, `df`, `free` manualmente — todas as métricas à vista

| Visão Geral do Monitoramento em Tempo Real | Alternância por Host |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

- **CPU / Memória / Disco / Rede** — quatro métricas principais atualizadas em tempo real
- **Monitoramento paralelo multi-host** — visualize todos os seus servidores em um único painel
- **Alternância independente por host** — desative o monitoramento de qualquer máquina a qualquer momento
- Destaque automático de métricas anormais — identifique problemas instantaneamente

### 📝 Registro de Alterações e Logs de Auditoria

> Quem mudou o quê, e quando? Totalmente rastreável. Análise pós-incidente facilitada.

- **Registro automático de todas as operações do Agent**: execução de comandos, alterações de arquivos, modificações de configuração
- **Gerenciamento de janela de alterações**: alterações planejadas vs emergenciais, categorizadas
- **Logs de auditoria completos**: operador, data/hora, comando, resultado, código de saída — tudo consultável
- **Sugestões de rollback**: a IA analisa o impacto da alteração e recomenda planos de rollback

### 📋 Runbooks Ops

| Lista de Runbooks | Executando |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

- **Modelos comuns de ops integrados**: inspeção do sistema, endurecimento de segurança, limpeza de logs, implantação de serviços e muito mais
- **Execução com um clique**: não precisa digitar comandos passo a passo — os runbooks executam automaticamente
- **Orquestração multi-host**: execute o mesmo fluxo de trabalho em vários servidores em paralelo ou sequencialmente
- **Runbooks personalizados**: crie seus próprios playbooks de ops e codifique o conhecimento da equipe

### 🔔 Central de Notificações

- **Alertas de conclusão de tarefa** — seja notificado no momento em que tarefas de longa duração terminam
- **Alertas de anomalia** — violações de limiar de monitoramento, falhas de comando, enviadas instantaneamente
- **Lembretes de segurança** — operações de alto risco, comportamento suspeito, avisos antecipados
- **Políticas de notificação configuráveis** — você decide quais eventos acionam notificações

### 🎨 Redesign da UI de Glassmorfismo

| Configurações (Chinês) | Configurações (Inglês) |
|:---:|:---:|
| <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面_英文版.jpg" width="400" /> |

- Novo design de cartão **GlassCard de glassmorfismo** com hierarquia visual mais clara
- **Refatoração do sistema de temas** — cores de tema personalizadas, raio de canto, intensidade de desfoque
- Transições animadas mais suaves, feedback de interação mais refinado
- **15+ idiomas** com troca com um clique

| Configurações Multi-idioma |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

## 💡 O que ele pode fazer por você?

### Instalar software? Basta dizer.

> 💬 "Instale o Docker neste servidor"

A IA detecta sua versão do SO, corresponde à documentação oficial, executa os comandos de instalação e verifica se funcionou. Zero comandos para memorizar.

### Configurar ambientes? Chega de dor de cabeça com PATH.

> 💬 "Configure o Python 3.12 com as variáveis de ambiente adequadas"

A IA sabe que Debian usa `apt`, CentOS usa `yum`, macOS usa `brew`. Ela não adivinha — segue estritamente a documentação oficial.

### Verificar vulnerabilidades? Ela é mais paranóica que você.

> 💬 "Verifique meu servidor quanto a problemas de segurança"

A IA executa verificações de atualização do sistema, varreduras de portas e auditorias de processo automaticamente. Você recebe um relatório completo do que corrigir.

### Ler logs? Chega de procurar em favoritos.

> 💬 "Mostre-me os erros recentes do Nginx"

A IA sabe onde os logs ficam, como filtrá-los e o que importa. Informações chave, sem malabarismos com `tail -f`.

### Gerenciar servidores? Várias máquinas, uma interface.

Conexões remotas SSH com pool de conexões. Alterne entre servidores com zero atraso. Várias abas, uma conexão compartilhada.

## 🛡️ Segurança: O elefante na sala

Entregar seu servidor a uma IA parece aterrorizante. Três preocupações válidas:

### 🔐 "Para onde vão minhas senhas?"

```
Sua senha → Armazenamento seguro em nível de sistema (macOS Keychain / Android Keystore)
                       ↓
              Banco de dados local armazena apenas "qual chave foi usada", nunca a senha em si
                       ↓
              Senhas nunca aparecem em texto claro em logs, arquivos de configuração ou no disco
```

Mesmo que alguém roube seu dispositivo, sem sua biometria/senha, tudo o que eles terão são dados criptografados ilegíveis.

### 🤖 "A IA pode sair do controle?"

**Não.** Três camadas de defesa:

```
┌─────────────────────────────────────────────────────┐
│ Camada 1: Prompts de Limite de Comportamento        │
│ As instruções do sistema de IA proíbem explicitamente:│
│   ✗ Instalar/desinstalar software sem pedir         │
│   ✗ Modificar variáveis de ambiente ou configurações do sistema │
│   ✗ Executar operações destrutivas                  │
│   ✓ Solicitações de "verificação/inspeção" → comandos somente leitura │
│   ✓ Problemas encontrados → relatar primeiro, nunca corrigir sozinho │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Camada 2: Classificação de Comandos SafetyGuard     │
│ Cada comando é revisado antes da execução:          │
│   🔴 bloqueado → Bloqueado imediatamente, nunca executa │
│      (rm -rf /, chmod 777, formatação de disco, etc.) │
│   🟡 avisar → Popup de aviso, requer entrada CONFIRMAR │
│      (apt install, systemctl stop, alterações de firewall) │
│   🔵 info → Aviso de baixo risco, executa normalmente │
│      (curl, wget, ls, cat, etc.)                    │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Camada 3: Você é o Portão Final                     │
│ Você é sempre a última linha de defesa.             │
│ Comandos de nível de aviso não executam sem CONFIRMAR. │
│ Você pode interromper, cancelar ou revisar a qualquer momento. │
└─────────────────────────────────────────────────────┘
```

### 📋 Carta de Comportamento do Agent

| O que você pode pedir | O que a IA fará | O que a IA não fará |
|:---|:---|:---|
| Instalar software | Gerar comandos oficiais de instalação e executá-los | Decidir qual versão instalar por conta própria |
| Verificar segurança | Executar comandos de auditoria e relatar descobertas | Corrigir problemas sem sua permissão |
| Configurar ambiente | Seguir exatamente a documentação oficial | Alterar parâmetros do sistema que você não pediu |
| Ler logs | Filtrar e mostrar informações chave | Excluir ou modificar arquivos de log |
| Gerenciar serviços | Iniciar/parar os serviços que você especificou | Iniciar outros serviços que você não mencionou |
| Executar fluxos de trabalho | Executar etapas pré-definidas automaticamente | Pular etapas críticas ou modificar o processo |

**Resumindo: A IA é sua assistente, não sua chefe. Ela faz o que você pede. Nada mais.**

## ✨ Funcionalidades Principais

| Funcionalidade | Descrição |
|:---|:---|
| 🤖 **Execução Automática do Agent** | A IA gera comandos e os executa em loop até a conclusão da tarefa |
| 📊 **Monitoramento do Servidor** | Painel de CPU/memória/disco/rede em tempo real, multi-host paralelo |
| 📝 **Registros de Alterações** | Logs de auditoria completos, operações rastreáveis, prontos para rollback |
| 📋 **Runbooks Ops** | Modelos de Runbook integrados, tarefas comuns de ops com um clique |
| 🔔 **Central de Notificações** | Conclusão de tarefa, alertas de anomalia, lembretes de segurança — enviados instantaneamente |
| 🛡️ **Tripla Segurança** | Prompts de limite de comportamento → Classificação de comandos SafetyGuard → Operações perigosas requerem CONFIRMAR |
| 🔐 **Zero Credenciais em Texto Claro** | Senhas/chaves privadas no Keychain / Keystore do sistema, nunca em texto claro no disco |
| 🖥️ **5 Plataformas Nativas** | macOS / Linux / Windows / Android / iOS — suporte nativo completo |
| 📡 **Local + Remoto** | Conexões remotas SSH + terminal PTY local; o Agent funciona em ambos os modos |
| 🔄 **Pool de Conexões** | Pool de conexões SSH — várias abas compartilham uma conexão, troca com zero atraso |
| 🌊 **Saída em Streaming** | Respostas da IA renderizam em tempo real; saída do terminal transmite ao vivo |
| 🧠 **Baseado em Conhecimento** | Mais de 150 guias de instalação/configuração de software integrados — segue documentação oficial, sem alucinação de IA |
| 🌐 **20+ Provedores** | DeepSeek / Qwen / Claude / Gemini / Ollama e mais, com atualizações remotas de configuração |
| 🌍 **15+ Idiomas** | Chinês / Inglês / Japonês / Coreano / Francês / Alemão / Espanhol / Russo / Português e mais |

## 🏗️ Pilha Tecnológica

```
Flutter 3.16+ (Dart 3.2+)
├── Gerenciamento de Estado: Riverpod
├── Roteamento: GoRouter
├── Armazenamento Local: Hive + flutter_secure_storage
├── SSH: dartssh2
├── Terminal Local: flutter_pty
├── UI do Terminal: xterm.dart
├── Interface de IA: Compatível com OpenAI (20+ provedores)
├── Monitoramento: Painel do servidor (CPU/memória/disco/rede)
├── Ops: Registros de alteração + Logs de auditoria + Fluxos de trabalho Runbook
└── UI: Glassmorfismo GlassCard + Multi-tema + 15+ idiomas
```

## 🚀 Começando

### Pré-requisitos

- Flutter 3.16.0+
- Dart 3.2.0+
- Ferramentas de desenvolvimento específicas da plataforma (Xcode / Android Studio / VS Code, etc.)

### Instalar e Executar

```bash
# Clone o repositório
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

# Instale as dependências
flutter pub get

# Gere os Adaptadores Hive (apenas na primeira vez)
dart run build_runner build --delete-conflicting-outputs

# Execute
flutter run
```

### Construir para Release

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android APK
flutter build apk --release

# iOS (requer macOS + certificado de desenvolvedor)
flutter build ios --release
```

> 📥 Ou baixe binários pré-compilados em [Releases](https://github.com/keiskeies/ai_terminal/releases).

## 🔧 Configurando Modelos de IA

O aplicativo vem com **20+ predefinições de provedores de IA** e suporta qualquer **API compatível com OpenAI**:

| Categoria | Provedores |
|:---|:---|
| 🏠 Local | Ollama (totalmente gratuito, não precisa de chave API) |
| 🇨🇳 Nuvem da China | DeepSeek / Qwen / GLM / Kimi / Doubao / MiMo / MiniMax / SiliconFlow / StepFun / Baichuan / Spark / Hunyuan |
| 🌍 Nuvem Global | OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq |
| 🔧 Personalizado | Qualquer endpoint de API compatível com OpenAI |

Etapas de configuração:

1. Abra o aplicativo → Configurações → Configuração do Modelo de IA
2. Clique em `+` para adicionar um modelo
3. Selecione um provedor (URL Base e modelos recomendados são preenchidos automaticamente)
4. Digite sua Chave API e selecione um modelo
5. Defina como modelo padrão

> 💡 A lista de provedores suporta atualizações remotas: clique no botão 🔄 ao lado do menu suspenso de provedor para buscar os provedores e modelos mais recentes do servidor — sem necessidade de atualizar o aplicativo

## 📱 Capturas de Tela

| UI Principal (Monitor + Terminal) | Orquestração Multi-Host |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

| Runbooks Ops | Página de Configurações |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

| Configurações Multi-idioma |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

> 🤖 Recursos de IA alimentados por <b>Xiaomi MiMo</b> LLM

## 📖 Demonstração: Instalação Automática Baseada em Conhecimento

A v1.3.0 introduziu uma **Base de Conhecimento de Manual de Comandos** — mais de 150 guias oficiais de instalação/desinstalação/atualização. O Agent corresponde automaticamente à base de conhecimento e segue estritamente os métodos oficiais, **eliminando a alucinação de IA**.

Abaixo: digitando "install openclaw" após conectar por SSH em um servidor Ubuntu:

| ① Digite o comando | ② Correspondência na base de conhecimento, gerar comandos |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_1.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_2.webp" width="400" /> |

| ③ Executar instalação automaticamente | ④ Verificar instalação |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_3.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_4.webp" width="400" /> |

**Detalhamento do fluxo:**

1. Usuário digita "install openclaw" → Agent extrai a operação (instalar) e a plataforma (linux)
2. Base de conhecimento corresponde a `openclaw` para `linux-debian` (modo estrito), injetando comandos oficiais de instalação
3. Agent segue exatamente a base de conhecimento: instala Node.js 22, depois `npm install -g openclaw`
4. Verificação pós-instalação: executa `openclaw --version` para confirmar o sucesso

> 💡 A base de conhecimento suporta correspondência específica por plataforma (`linux-debian` vs `linux-rhel` geram comandos de gerenciador de pacotes diferentes), com atualizações remotas com um clique

## 🗺️ Roadmap

- [x] v1.0.0 — Lançamento da funcionalidade principal
  - [x] Terminal remoto SSH + terminal PTY local
  - [x] Chat de IA + geração de comandos + execução automática
  - [x] Verificação de segurança de comandos SafetyGuard
  - [x] Armazenamento criptografado de credenciais
  - [x] Configuração multi-modelo
- [x] v1.1.0 — Melhoria da UI
  - [x] Redesign do layout do painel de IA
  - [x] Orientação automática em dispositivos móveis
  - [x] Tema verde do modo Agent
- [x] v1.2.0 — Aumento da inteligência do Agent
  - [x] Histórico de conversas persistente entre tarefas
  - [x] Saída de comando de consulta não é mais truncada
  - [x] Etapas de execução ilimitadas por padrão
  - [x] Gerenciamento de arquivos SFTP + edição remota
- [x] v1.3.0 — Baseado em conhecimento
  - [x] 🧠 Base de conhecimento de busca de texto completo SQLite FTS5 (mais de 150 guias de software)
  - [x] 🔄 Sincronização automática da base de conhecimento remota (atualiza do GitHub no lançamento)
  - [x] 🎯 Correspondência específica por plataforma (linux-debian / linux-rhel / macos)
  - [x] 🛡️ Regras de segurança LLM (aplicação estrita + proibição de comando de busca)
  - [x] 🔧 Ferramenta de construção da base de conhecimento (CSV → SQLite)
  - [x] 💬 Mensagens amigáveis de erro de API (401/429/timeout)
- [x] v1.3.1 — Ecossistema de provedores
  - [x] 🌐 20+ predefinições de provedores de IA (12 China + 8 Global + Ollama + Personalizado)
  - [x] 🔄 Atualizações remotas de configuração de provedor (sem necessidade de atualizar o aplicativo)
  - [x] 🏷️ Descrições de provedores e informações de preços
  - [x] 🤖 Seleção rápida de modelo predefinido (com um clique)
  - [x] 🦙 Implantação local Ollama (sem chave API, totalmente gratuito)
  - [x] 📐 Otimização da caixa de diálogo de adição de modelo (layout de duas colunas em tela ampla)
- [x] v1.3.6 — Mega Atualização de Capacidades de Ops
  - [x] 📊 Monitoramento de servidor em tempo real (CPU/memória/disco/rede, multi-host paralelo)
  - [x] 📝 Registros de alteração e logs de auditoria (histórico completo de operações, rastreável e pronto para rollback)
  - [x] 📋 Runbooks Ops (modelos integrados + personalizados, execução com um clique)
  - [x] 🔔 Central de Notificações (conclusão de tarefa, alertas de anomalia, lembretes de segurança)
  - [x] 🎨 Redesign da UI de glassmorfismo (design GlassCard, atualização do sistema de temas)
  - [x] 🌍 Localização em 15+ idiomas
  - [x] 📺 Orquestração multi-host (executar fluxos de trabalho em servidores em paralelo/sequencial)

## 🤝 Contribuindo

Contribuições bem-vindas! Relatórios de bugs, sugestões de funcionalidades ou código.

1. Faça um fork deste repositório
2. Crie um branch de funcionalidade (`git checkout -b feature/funcionalidade-incrivel`)
3. Faça commit das suas alterações (`git commit -m 'Adiciona funcionalidade incrível'`)
4. Faça push para o branch (`git push origin feature/funcionalidade-incrivel`)
5. Abra um Pull Request

## 📄 Licença

[Licença MIT](./LICENSE)

---

## ⭐ Histórico de Estrelas

[![Gráfico de Histórico de Estrelas](https://api.star-history.com/svg?repos=keiskeies/ai_terminal&type=Date)](https://star-history.com/#keiskeies/ai_terminal&Date)

---

<p align="center">
  Se este projeto te ajuda, por favor dê uma ⭐ Estrela!
</p>
