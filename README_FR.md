<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>Contrôlez vos serveurs avec le langage naturel. L'IA exécute les commandes pour vous.</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top" target="_blank">🌐 Site web</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/releases" target="_blank">📦 Télécharger</a> ·
    <a href="./QUESTION.md">❓ FAQ</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Plateforme" />
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="Licence" />
    <img src="https://img.shields.io/badge/version-1.3.5-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**🌍 Langue :**
[中文](./README.md) | [English](./README_EN.md) | [日本語](./README_JA.md) | [Deutsch](./README_DE.md) | **Français** | [Español](./README_ES.md) | [한국어](./README_KO.md) | [Русский](./README_RU.md) | [Português](./README_PT.md) | [Italiano](./README_IT.md)

---

## En une phrase

> **Jamais utilisé de terminal ? Pas de problème.** Ouvrez AI Terminal, dites-lui ce que vous voulez en langage clair — il se connecte à votre serveur, exécute les commandes, installe les logiciels et résout les problèmes. Tout en toute sécurité et sous votre contrôle.

## 🎯 Ça vous parle ?

### 😫 Débutants / Utilisateurs non techniques

- Vous avez loué un VPS, ouvert le terminal et regardé un **écran noir** sans savoir quoi taper
- Un ami a dit « installe juste Nginx » — vous avez cherché 10 tutoriels sur Google, chacun avec des commandes différentes
- Vous avez essayé de configurer Java, mal édité `PATH` et cassé tout votre terminal
- Quelqu'un vous a averti d'une vulnérabilité serveur — vous ne savez même pas comment vérifier
- Après 3 heures de bidouillage, rien ne marche. Vous abandonnez.

### 👨‍💻 Développeurs

- Vous cherchez les mêmes commandes `chmod` / `systemctl` sur Google à chaque fois
- Vous vous connectez en SSH à un serveur, mais oubliez les exacts drapeaux `grep` dont vous avez besoin
- Vous voulez consulter les logs ? D'abord, retrouvez ce marque-page d'il y a 6 mois
- 15 onglets de navigateur ouverts, vous passez d'un serveur à l'autre, vous perdez le fil

### 🔧 DevOps / Administrateurs système

- Même logiciel sur 10 serveurs ? Connexion SSH sur chacun et répétez. Encore.
- « Qui a modifié cette config ? » — personne ne se souvient, rien n'est journalisé
- Un nouveau demande « comment configurer l'environnement ? » — vous l'avez expliqué 5 fois ce mois-ci
- Vous voulez faire un check de santé en lot ? Écrire le script prend plus de temps que de le faire manuellement

### 🧑‍💼 Chefs de produit / Fondateurs solo

- Votre seul développeur est parti. Le serveur est maintenant une boîte noire.
- Vous devez vérifier des données mais ne savez pas écrire de SQL. Vous devez demander à quelqu'un.
- Déployer un changement de config nécessite un sprint dev. C'est littéralement une ligne.
- Vous portez 5 casquettes. Vous n'avez pas le temps d'apprendre `vi`.

**Tous ces scénarios ? Une phrase à AI Terminal et c'est réglé.**

## 🆕 Nouveautés de la v1.3.5

La v1.3.5 est une mise à jour majeure avec **5 nouvelles fonctionnalités principales** : Surveillance du serveur, Journal des changements, Runbooks Ops, Centre de notifications, et UI glassmorphisme — une amélioration complète pour l'efficacité DevOps.

### 📊 Tableau de bord de surveillance serveur en temps réel

> Plus besoin de taper manuellement `top`, `df`, `free` — toutes les métriques en un coup d'œil

| Vue d'ensemble de la surveillance en temps réel | Basculer par hôte |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

- **CPU / Mémoire / Disque / Réseau** — quatre métriques principales actualisées en temps réel
- **Surveillance parallèle multi-hôtes** — visualisez tous vos serveurs depuis un seul tableau de bord
- **Bascule indépendante par hôte** — désactivez la surveillance pour n'importe quelle machine à tout moment
- Mise en évidence automatique des métriques anormales — détectez les problèmes instantanément

### 📝 Journal des changements & journaux d'audit

> Qui a changé quoi, et quand ? Entièrement traçable. L'investigation post-incident est facilitée.

- **Journalisation automatique de toutes les opérations de l'Agent** : exécution de commandes, modifications de fichiers, modifications de configuration
- **Gestion des fenêtres de changement** : changements planifiés vs urgences, catégorisés
- **Journaux d'audit complets** : opérateur, horodatage, commande, résultat, code de sortie — tout est interrogeable
- **Suggestions de restauration** : l'IA analyse l'impact des changements et recommande des plans de restauration

### 📋 Runbooks Ops

| Liste des Runbooks | En cours d'exécution |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

- **Modèles d'opérations courants intégrés** : inspection système, durcissement de sécurité, nettoyage de logs, déploiement de services, et plus encore
- **Exécution en un clic** : plus besoin de taper les commandes étape par étape — les runbooks s'exécutent automatiquement
- **Orchestration multi-hôtes** : exécutez le même workflow sur plusieurs serveurs en parallèle ou séquentiellement
- **Runbooks personnalisés** : créez vos propres playbooks d'opérations et codifiez la connaissance de l'équipe

### 🔔 Centre de notifications

- **Alertes de fin de tâche** — soyez notifié au moment où les tâches de longue durée se terminent
- **Alertes d'anomalie** — dépassements de seuils de surveillance, échecs de commandes, envoyés instantanément
- **Rappels de sécurité** — opérations à haut risque, comportements suspects, avertissements précoces
- **Politiques de notification configurables** — vous décidez quels événements déclenchent des notifications

### 🎨 Refonte de l'UI glassmorphisme

| Paramètres (Chinois) | Paramètres (Anglais) |
|:---:|:---:|
| <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面_英文版.jpg" width="400" /> |

- Tout nouveau **design de carte GlassCard en glassmorphisme** avec une hiérarchie visuelle plus claire
- **Refonte du système de thèmes** — couleurs de thème personnalisées, rayon des coins, intensité du flou
- Transitions animées plus fluides, retour d'interaction plus raffiné
- **15+ langues** avec basculement en un clic

| Paramètres multilingues |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

## 💡 Qu'est-ce que ça peut faire pour vous ?

### Installer un logiciel ? Dites-le simplement.

> 💬 « Installe Docker sur ce serveur »

L'IA détecte votre version de système d'exploitation, correspond à la documentation officielle, exécute les commandes d'installation et vérifie que ça a fonctionné. Zéro commande à mémoriser.

### Configurer des environnements ? Plus de maux de tête avec PATH.

> 💬 « Configure Python 3.12 avec les variables d'environnement appropriées »

L'IA sait que Debian utilise `apt`, CentOS utilise `yum`, macOS utilise `brew`. Elle ne devine pas — elle suit strictement la documentation officielle.

### Vérifier les vulnérabilités ? C'est plus paranoïaque que vous.

> 💬 « Analysez mon serveur à la recherche de problèmes de sécurité »

L'IA exécute automatiquement des vérifications de mises à jour système, des analyses de ports et des audits de processus. Vous obtenez un rapport complet de ce qu'il faut corriger.

### Consulter les logs ? Plus besoin de fouiller dans les marque-pages.

> 💬 « Montrez-moi les erreurs Nginx récentes »

L'IA sait où se trouvent les logs, comment les filtrer et ce qui compte. Informations clés, pas de gymnastique avec `tail -f`.

### Gérer des serveurs ? Plusieurs machines, une seule interface.

Connexions distantes SSH avec pool de connexions. Basculez entre les serveurs sans délai. Plusieurs onglets, une connexion partagée.

## 🛡️ Sécurité : L'éléphant dans la pièce

Confier son serveur à une IA, ça fait peur. Trois préoccupations valides :

### 🔐 « Où vont mes mots de passe ? »

```
Votre mot de passe → Stockage sécurisé au niveau système (macOS Keychain / Android Keystore)
                       ↓
              La base de données locale ne stocke que « quelle clé a été utilisée », jamais le mot de passe lui-même
                       ↓
              Les mots de passe n'apparaissent jamais en clair dans les logs, les fichiers de config ou sur le disque
```

Même si quelqu'un vole votre appareil, sans votre biométrie/code secret, il n'obtiendra que du charabia chiffré.

### 🤖 « L'IA peut-elle dérailler ? »

**Non.** Trois couches de défense :

```
┌─────────────────────────────────────────────────────┐
│ Couche 1 : Prompts de limites de comportement        │
│ Les instructions système de l'IA interdisent explicitement : │
│   ✗ Installer/désinstaller des logiciels sans demander  │
│   ✗ Modifier les variables d'environnement ou les configs système │
│   ✗ Exécuter des opérations destructrices             │
│   ✓ Requêtes « vérifier/inspecter » → commandes en lecture seule │
│   ✓ Problèmes trouvés → rapport d'abord, jamais d'auto-réparation │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Couche 2 : Classification des commandes SafetyGuard │
│ Chaque commande est examinée avant exécution :      │
│   🔴 bloquée → Bloquée immédiatement, ne s'exécute jamais │
│      (rm -rf /, chmod 777, formatage de disque, etc.)    │
│   🟡 avertissement → Popup d'avertissement, nécessite une saisie CONFIRM │
│      (apt install, systemctl stop, modifications de pare-feu) │
│   🔵 info → Avertissement à faible risque, s'exécute normalement │
│      (curl, wget, ls, cat, etc.)                     │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Couche 3 : Vous êtes la porte finale                 │
│ Vous êtes toujours la dernière ligne de défense.     │
│ Les commandes de niveau avertissement ne s'exécutent pas sans CONFIRM. │
│ Vous pouvez interrompre, annuler ou vérifier à tout moment. │
└─────────────────────────────────────────────────────┘
```

### 📋 Charte de comportement de l'Agent

| Ce que vous pouvez demander | Ce que l'IA fera | Ce que l'IA ne fera pas |
|:---|:---|:---|
| Installer un logiciel | Générer les commandes d'installation officielles et les exécuter | Décider seule quelle version installer |
| Vérifier la sécurité | Exécuter les commandes d'audit et rapporter les résultats | Corriger les problèmes sans votre permission |
| Configurer l'environnement | Suivre exactement la documentation officielle | Modifier les paramètres système que vous n'avez pas demandés |
| Consulter les logs | Filtrer et afficher les informations clés | Supprimer ou modifier les fichiers de logs |
| Gérer les services | Démarrer/arrêter les services que vous avez spécifiés | Démarrer d'autres services que vous n'avez pas mentionnés |
| Exécuter des workflows | Exécuter automatiquement les étapes prédéfinies | Sauter des étapes critiques ou modifier le processus |

**En bref : L'IA est votre assistante, pas votre patronne. Elle fait ce que vous demandez. Rien de plus.**

## ✨ Fonctionnalités principales

| Fonctionnalité | Description |
|:---|:---|
| 🤖 **Auto-exécution de l'Agent** | L'IA génère des commandes et les exécute en boucle jusqu'à l'achèvement de la tâche |
| 📊 **Surveillance du serveur** | Tableau de bord CPU/mémoire/disque/réseau en temps réel, multi-hôtes parallèle |
| 📝 **Journal des changements** | Journaux d'audit complets, opérations traçables, prêtes pour la restauration |
| 📋 **Runbooks Ops** | Modèles de Runbook intégrés, tâches d'opérations courantes en un clic |
| 🔔 **Centre de notifications** | Fin de tâche, alertes d'anomalie, rappels de sécurité — envoyés instantanément |
| 🛡️ **Triple sécurité** | Prompts de limites de comportement → Classification des commandes SafetyGuard → Opérations dangereuses nécessitent CONFIRM |
| 🔐 **Zéro identifiant en clair** | Mots de passe/clés privées dans le Keychain/Keystore système, jamais sur le disque en clair |
| 🖥️ **5 plates-formes natives** | macOS / Linux / Windows / Android / iOS — support natif complet |
| 📡 **Local + Distant** | Connexions distantes SSH + terminal PTY local ; l'Agent fonctionne dans les deux modes |
| 🔄 **Pool de connexions** | Pool de connexions SSH — plusieurs onglets partagent une connexion, basculement sans délai |
| 🌊 **Sortie en flux** | Les réponses de l'IA se rendent en temps réel ; la sortie du terminal diffuse en direct |
| 🧠 **Axé sur la connaissance** | 150+ guides d'installation/configuration de logiciels intégrés — suit la documentation officielle, pas d'hallucination IA |
| 🌐 **20+ fournisseurs** | DeepSeek / Qwen / Claude / Gemini / Ollama et plus, avec mises à jour de config distantes |
| 🌍 **15+ langues** | Chinois / Anglais / Japonais / Coréen / Français / Allemand / Espagnol / Russe / Portugais et plus |

## 🏗️ Stack technique

```
Flutter 3.16+ (Dart 3.2+)
├── Gestion d'état : Riverpod
├── Routage : GoRouter
├── Stockage local : Hive + flutter_secure_storage
├── SSH : dartssh2
├── Terminal local : flutter_pty
├── UI de terminal : xterm.dart
├── Interface IA : compatible OpenAI (20+ fournisseurs)
├── Surveillance : Tableau de bord serveur (CPU/mémoire/disque/réseau)
├── Ops : Journal des changements + Journaux d'audit + Workflows Runbook
└── UI : Glassmorphisme GlassCard + Multi-thème + 15+ langues
```

## 🚀 Pour commencer

### Prérequis

- Flutter 3.16.0+
- Dart 3.2.0+
- Outils de développement spécifiques à la plate-forme (Xcode / Android Studio / VS Code, etc.)

### Installation & exécution

```bash
# Cloner le dépôt
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

# Installer les dépendances
flutter pub get

# Générer les adaptateurs Hive (première fois seulement)
dart run build_runner build --delete-conflicting-outputs

# Exécuter
flutter run
```

### Compiler pour la mise en production

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android APK
flutter build apk --release

# iOS (nécessite macOS + certificat développeur)
flutter build ios --release
```

> 📥 Ou téléchargez les binaires précompilés depuis [Releases](https://github.com/keiskeies/ai_terminal/releases).

## 🔧 Configuration des modèles IA

L'application est livrée avec **20+ préréglages de fournisseurs IA** et prend en charge toute **API compatible OpenAI** :

| Catégorie | Fournisseurs |
|:---|:---|
| 🏠 Local | Ollama (complètement gratuit, aucune clé API nécessaire) |
| 🇨🇳 Cloud Chine | DeepSeek / Qwen / GLM / Kimi / Doubao / MiMo / MiniMax / SiliconFlow / StepFun / Baichuan / Spark / Hunyuan |
| 🌍 Cloud mondial | OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq |
| 🔧 Personnalisé | Tout point de terminaison d'API compatible OpenAI |

Étapes de configuration :

1. Ouvrez l'application → Paramètres → Configuration du modèle IA
2. Cliquez sur `+` pour ajouter un modèle
3. Sélectionnez un fournisseur (l'URL de base et les modèles recommandés sont auto-remplis)
4. Entrez votre clé API et sélectionnez un modèle
5. Définissez comme modèle par défaut

> 💡 La liste des fournisseurs prend en charge les mises à jour à distance : cliquez sur le bouton 🔄 à côté du menu déroulant des fournisseurs pour récupérer les derniers fournisseurs et modèles depuis le serveur — aucune mise à jour d'application nécessaire

## 📱 Captures d'écran

| Interface principale (Surveillance + Terminal) | Orchestration multi-hôtes |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

| Runbooks Ops | Page des paramètres |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

| Paramètres multilingues |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

> 🤖 Fonctionnalités IA propulsées par <b>Xiaomi MiMo</b> LLM

## 📖 Démo : Installation automatique axée sur la connaissance

La v1.3.0 a introduit une **Base de connaissances du manuel de commandes** — 150+ guides officiels d'installation/désinstallation/mise à jour. L'Agent correspond automatiquement à la base de connaissances et suit strictement les méthodes officielles, **éliminant l'hallucination de l'IA**.

Ci-dessous : taper « installer openclaw » après s'être connecté en SSH à un serveur Ubuntu :

| ① Entrer la commande | ② Correspondance avec la base de connaissances, générer les commandes |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_1.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_2.webp" width="400" /> |

| ③ Exécuter automatiquement l'installation | ④ Vérifier l'installation |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_3.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_4.webp" width="400" /> |

**Détail du flux :**

1. L'utilisateur tape « installer openclaw » → L'Agent extrait l'opération (installer) et la plate-forme (linux)
2. La base de connaissances correspond à `openclaw` pour `linux-debian` (mode strict), injectant les commandes d'installation officielles
3. L'Agent suit exactement la base de connaissances : installe Node.js 22, puis `npm install -g openclaw`
4. Vérification post-installation : exécute `openclaw --version` pour confirmer le succès

> 💡 La base de connaissances prend en charge la correspondance spécifique à la plate-forme (`linux-debian` vs `linux-rhel` produisent différentes commandes de gestionnaire de paquets), avec mises à jour à distance en un clic

## 🗺️ Feuille de route

- [x] v1.0.0 — Sortie des fonctionnalités de base
  - [x] Terminal distant SSH + terminal PTY local
  - [x] Chat IA + génération de commandes + auto-exécution
  - [x] Vérification de sécurité des commandes SafetyGuard
  - [x] Stockage chiffré des identifiants
  - [x] Configuration multi-modèles
- [x] v1.1.0 — Amélioration de l'UI
  - [x] Refonte de la disposition du panneau IA
  - [x] Orientation automatique sur mobile
  - [x] Thème vert du mode Agent
- [x] v1.2.0 — Boost d'intelligence de l'Agent
  - [x] Historique de conversation persistant entre les tâches
  - [x] La sortie des commandes de requête n'est plus tronquée
  - [x] Étapes d'exécution illimitées par défaut
  - [x] Gestion de fichiers SFTP + édition distante
- [x] v1.3.0 — Axé sur la connaissance
  - [x] 🧠 Base de connaissances de recherche en texte intégral SQLite FTS5 (150+ guides logiciels)
  - [x] 🔄 Synchronisation automatique de la base de connaissances distante (mises à jour depuis GitHub au lancement)
  - [x] 🎯 Correspondance spécifique à la plate-forme (linux-debian / linux-rhel / macos)
  - [x] 🛡️ Règles de sécurité LLM (application stricte + interdiction des commandes de recherche)
  - [x] 🔧 Outil de construction de base de connaissances (CSV → SQLite)
  - [x] 💬 Messages d'erreur API conviviaux (401/429/timeout)
- [x] v1.3.1 — Écosystème de fournisseurs
  - [x] 🌐 20+ préréglages de fournisseurs IA (12 Chine + 8 Mondial + Ollama + Personnalisé)
  - [x] 🔄 Mises à jour de config fournisseur à distance (aucune mise à jour d'application nécessaire)
  - [x] 🏷️ Descriptions des fournisseurs et informations sur les tarifs
  - [x] 🤖 Sélection rapide de modèles préréglés (en un clic)
  - [x] 🦙 Déploiement local Ollama (pas de clé API, complètement gratuit)
  - [x] 📐 Optimisation de la boîte de dialogue d'ajout de modèle (disposition à deux colonnes pour grand écran)
- [x] v1.3.5 — Mise à niveau majeure des capacités Ops
  - [x] 📊 Surveillance serveur en temps réel (CPU/mémoire/disque/réseau, multi-hôtes parallèle)
  - [x] 📝 Journal des changements & journaux d'audit (historique complet des opérations, traçable & prêt pour la restauration)
  - [x] 📋 Runbooks Ops (modèles intégrés + personnalisés, exécution en un clic)
  - [x] 🔔 Centre de notifications (fin de tâche, alertes d'anomalie, rappels de sécurité)
  - [x] 🎨 Refonte de l'UI glassmorphisme (design GlassCard, mise à niveau du système de thèmes)
  - [x] 🌍 Localisation en 15+ langues
  - [x] 📺 Orchestration multi-hôtes (exécuter des workflows sur plusieurs serveurs en parallèle/série)

## 🤝 Contribuer

Les contributions sont les bienvenues ! Rapports de bugs, suggestions de fonctionnalités ou code.

1. Fork ce dépôt
2. Créez une branche de fonctionnalité (`git checkout -b feature/fonctionnalite-incroyable`)
3. Commitez vos changements (`git commit -m 'Ajouter une fonctionnalité incroyable'`)
4. Poussez vers la branche (`git push origin feature/fonctionnalite-incroyable`)
5. Ouvrez une Pull Request

## 📄 Licence

[Licence MIT](./LICENSE)

---

## ⭐ Historique des étoiles

[![Graphique de l'historique des étoiles](https://api.star-history.com/svg?repos=keiskeies/ai_terminal&type=Date)](https://star-history.com/#keiskeies/ai_terminal&Date)

---

<p align="center">
  Si ce projet vous aide, merci de lui donner une ⭐ Étoile !
</p>
