---
title: Erkenningen
description: De opensourcesoftware in Pullwatch, met de versie en de licentie van elk onderdeel.
---

Pullwatch is gratis en open source onder de [Apache License 2.0](https://github.com/alessandro823/pullwatch/blob/main/LICENSE). Het bevat de opensourcesoftware hieronder. De app heeft de volledige licentietekst van elk onderdeel aan boord: open **Over Pullwatch** en kies **Erkenningen**, of kies **Help**, **Erkenningen** terwijl er een venster van Pullwatch open is. De bestanden staan ook in de app zelf, in `Pullwatch.app/Contents/Resources/Acknowledgements/`, naast de eigen `LICENSE` en `NOTICE` van Pullwatch.

| Onderdeel | Versie | Licentie | Gebruikt voor |
|---|---|---|---|
| [Sparkle](https://sparkle-project.org) | 2.10.1 | MIT, met BSD (bsdiff, bspatch, SUSignatureVerifier), MIT (sais-lite) en zlib (Ed25519) voor de code die het meebrengt | Updates installeren |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache 2.0 en MIT (het project stapt over van MIT naar Apache 2.0) | De verbinding voor coding agents, in de app en in `pullwatch-mcp` |
| [SwiftLog](https://github.com/apple/swift-log) | 1.17.0 | Apache 2.0 | Logging in de MCP Swift SDK |
| [Swift System](https://github.com/apple/swift-system) | 1.8.1 | Apache 2.0 with the Runtime Library Exception | Systeemaanroepen in de MCP Swift SDK |
| [EventSource](https://github.com/mattt/eventsource) | 1.6.0 | MIT | Server-sent events in de MCP Swift SDK |
| [GitHub Octicons](https://github.com/primer/octicons) | 19.41.0 | MIT | De symbolen voor pull requests, checks en Branches, het icoon in de menubalk en het teken in het app-icoon |
| [Codeberg-logo](https://codeberg.org/Codeberg/Design) | 9f8c699 | CC0 1.0 | Het teken van een Codeberg-account |
| [Forgejo-logo](https://codeberg.org/forgejo/meta/src/branch/readme/branding) van Caesar Schinas | e34fea4 | CC BY-SA 4.0 | Het teken van een Forgejo-account |
| [simple-icons-swift](https://github.com/Vernum-Projecten/simple-icons-swift) | 16.36.2 | MIT | Het tekenen van de logo's van ecosystemen in Packages |
| [Simple Icons](https://simpleicons.org) | 16.36.0 | CC0 1.0 (de merken houden hun rechten) | De logo's van ecosystemen in Packages |
| [Rust-logo](https://www.rust-lang.org/policies/media-guide) van de Rust Foundation, uit Simple Icons | 16.36.0 | CC BY-SA 4.0 | Het logo van een Cargo-package in Packages |

De MCP Swift SDK haalt voor zijn eigen testtools ook SwiftNIO, Swift Atomics en Swift Collections binnen. Pullwatch linkt ze niet, dus ze zitten niet in de app.

GitHub, GitLab, Bitbucket, Azure DevOps, Codeberg, Forgejo en Gitea zijn merken van hun eigenaars. Pullwatch gebruikt hun namen alleen om te zeggen dat het ermee werkt, en is niet aan een van hen verbonden of door hen goedgekeurd. Het [NOTICE-bestand](https://github.com/alessandro823/pullwatch/blob/main/NOTICE) heeft de details.
