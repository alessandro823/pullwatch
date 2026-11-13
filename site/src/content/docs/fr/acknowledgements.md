---
title: Remerciements
description: "Les logiciels open source inclus dans Pullwatch, avec leur version et leur licence."
---

Pullwatch est gratuit et open source sous la [Apache License 2.0](https://github.com/alessandro823/pullwatch/blob/main/LICENSE). Il inclut les logiciels open source ci-dessous. L’app contient le texte complet de la licence de chacun : ouvrez **À propos de Pullwatch** et choisissez **Remerciements**, ou choisissez **Aide**, **Remerciements** quand une fenêtre de Pullwatch est ouverte. Les fichiers se trouvent aussi dans l’app elle-même, dans `Pullwatch.app/Contents/Resources/Acknowledgements/`, à côté des fichiers `LICENSE` et `NOTICE` de Pullwatch.

| Composant | Version | Licence | Utilisé pour |
|---|---|---|---|
| [Sparkle](https://sparkle-project.org) | 2.10.1 | MIT, avec BSD (bsdiff, bspatch, SUSignatureVerifier), MIT (sais-lite) et zlib (Ed25519) pour le code qu’il embarque | Installer les mises à jour |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache 2.0 et MIT (le projet passe de MIT à Apache 2.0) | La connexion des agents de code, dans l’app et dans `pullwatch-mcp` |
| [SwiftLog](https://github.com/apple/swift-log) | 1.17.0 | Apache 2.0 | La journalisation dans le MCP Swift SDK |
| [Swift System](https://github.com/apple/swift-system) | 1.8.1 | Apache 2.0 with the Runtime Library Exception | Les appels système dans le MCP Swift SDK |
| [EventSource](https://github.com/mattt/eventsource) | 1.6.0 | MIT | Les server-sent events dans le MCP Swift SDK |
| [GitHub Octicons](https://github.com/primer/octicons) | 19.41.0 | MIT | Les symboles des pull requests, des checks et de Branches, l’icône de la barre des menus et le motif de l’icône de l’app |
| [Logo Codeberg](https://codeberg.org/Codeberg/Design) | 9f8c699 | CC0 1.0 | Le symbole d’un compte Codeberg |
| [Logo Forgejo](https://codeberg.org/forgejo/meta/src/branch/readme/branding) par Caesar Schinas | e34fea4 | CC BY-SA 4.0 | Le symbole d’un compte Forgejo |
| [simple-icons-swift](https://github.com/Vernum-Projecten/simple-icons-swift) | 16.36.2 | MIT | Le dessin des logos des écosystèmes dans Paquets |
| [Simple Icons](https://simpleicons.org) | 16.36.0 | CC0 1.0 (les marques gardent leurs droits) | Les logos des écosystèmes dans Paquets |
| [Logo Rust](https://www.rust-lang.org/policies/media-guide) de la Rust Foundation, issu de Simple Icons | 16.36.0 | CC BY-SA 4.0 | Le logo d’un paquet Cargo dans Paquets |

Le MCP Swift SDK apporte aussi SwiftNIO, Swift Atomics et Swift Collections pour ses propres outils de test. Pullwatch ne les lie pas : ils ne font donc pas partie de l’app.

GitHub, GitLab, Bitbucket, Azure DevOps, Codeberg, Forgejo et Gitea sont des marques de leurs propriétaires. Pullwatch n’utilise leurs noms que pour indiquer qu’il fonctionne avec eux, et n’est ni affilié à aucun d’eux ni approuvé par aucun d’eux. Le [fichier NOTICE](https://github.com/alessandro823/pullwatch/blob/main/NOTICE) donne les détails.
