import Foundation
import os

private let logger = Log(category: "engine")

/// Pushes naar branches, op een eigen ronde (`pollBranches`) na de poll van PR's en tags, zodat
/// branches de PR's en tags nooit ophouden: ophalen bij de provider (`fetchBranches`) en verwerken tegen de
/// onthouden heads (`handleBranches`).
extension PollEngine {
    // MARK: - Ronde

    /// Haalt de branches op van de accounts die aan de beurt zijn (eens per `branchInterval`, niet
    /// tijdens een rate limit) en geeft de pushes, nieuwste eerst. Alleen voor accounts waarvan
    /// de laatste poll slaagde: de gebruiker daaruit bepaalt welke pushes van jezelf zijn, en de
    /// lijst van de dienst uit de tag-poll van net wordt hergebruikt. De app roept dit aan nadat
    /// ze de uitkomst van `poll` verwerkte; een trage of mislukte branch-poll houdt die dus niet op.
    public func pollBranches(accounts: [Account], retention: HistoryRetention = .oneYear) async -> [BranchPush] {
        let t = now()
        var jobs: [(account: Account, provider: any PRProvider, userId: String, repos: BranchRepos, listed: [String]?)] = []
        for account in accounts where !branchesInFlight.contains(account.id) {
            guard account.followsBranches else {
                // Volgt het account nergens meer branches: vergeten, zodat aanzetten opnieuw seedt.
                forgetBranchHeads(of: account, except: [])
                unreachable[account.id]?.branches = []
                continue
            }
            guard let job = branchJob(for: account, at: t) else { continue }
            let prefix = "\(account.id.uuidString):"
            let known = Dictionary(uniqueKeysWithValues: state.branchHeads
                .filter { $0.key.hasPrefix(prefix) }
                .map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            let listed = listedRepos[account.id].flatMap { t.timeIntervalSince($0.at) <= Self.branchInterval ? $0.repos : nil }
            let trees = Dictionary(uniqueKeysWithValues: state.repoBranches
                .filter { $0.key.hasPrefix(prefix) }
                .map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            let repos = BranchRepos(
                account: account, known: known, trees: trees,
                pullRequests: Self.branchPullRequests(openPullRequests[account.id] ?? []), treeBudget: branchTreeBudget)
            jobs.append((account, job.provider, job.userId, repos, listed))
        }
        let knownIdentities = identities
        guard !jobs.isEmpty else { return [] }
        // Markeer vóór de eerste suspensie, zodat een overlappende ronde deze accounts overslaat.
        for job in jobs { branchesInFlight.insert(job.account.id) }
        let jobsById = Dictionary(uniqueKeysWithValues: jobs.map { ($0.account.id, $0) })

        var pushes: [BranchPush] = []
        await withTaskGroup(of: (UUID, BranchOutcome, UserIdentity??).self) { group in
            for job in jobs {
                let known = knownIdentities[job.account.id]
                group.addTask {
                    let outcome = await Self.fetchBranches(job.provider, job.repos, listed: job.listed, at: t)
                    let identity = known != nil ? known : await Self.fetchIdentity(job.provider)
                    return (job.account.id, outcome, identity)
                }
            }
            for await (id, outcome, identity) in group {
                guard let job = jobsById[id] else { continue }
                if let identity { identities[id] = identity }
                pushes += handleBranches(
                    job.account, outcome, userId: job.userId, identity: identity ?? nil, provider: job.provider,
                    retention: retention, at: t)
                branchesInFlight.remove(id)
            }
        }
        saveState()
        return pushes.sorted {
            if $0.pushedAt != $1.pushedAt { return $0.pushedAt > $1.pushedAt }
            return ($0.repo.lowercased(), $0.branch) < ($1.repo.lowercased(), $1.branch)
        }
    }

    /// Waar een poll de branches van ophaalt: het account (eigen instellingen, standaard) en de
    /// onthouden heads per repo, met sleutels zonder accountprefix, lowercased.
    struct BranchRepos: Sendable {
        let account: Account
        let known: [String: BranchHeads]
        /// De boom per repo (lowercased), zoals de vorige poll hem achterliet.
        var trees: [String: RepoBranches] = [:]
        /// Per repo (lowercased) per bronbranch de open PR (`branchPullRequests`).
        var pullRequests: [String: [String: BranchPullRequest]] = [:]
        /// Vergelijkingen voor de boom in deze poll (`PollEngine.branchTreeBudget`).
        var treeBudget = PollEngine.branchTreeCompareLimit
    }

    /// Uitkomst van het ophalen van branches in één poll.
    struct BranchOutcome: Sendable {
        /// De repo's waarvan de branches gevolgd worden; bij branches als standaard uit de lijst
        /// van de dienst.
        var repos: [String]
        /// `nil` bij een fout.
        var fetch: BranchFetch?
        /// Vergelijkingen van veranderde heads, sleutel `branchKey(repo, branch)`.
        var comparisons: [String: BranchComparison]
        /// Fout die de branches van deze poll overslaat; het account faalt er nooit door.
        var error: ProviderError?
        /// De bijgewerkte boom per gelezen repo (lowercased); een onbereikbare repo ontbreekt.
        var trees: [String: RepoBranches] = [:]
    }

    /// Sleutel van `BranchOutcome.comparisons`: `"{repo.lowercased()}:{branch}"`.
    static func branchKey(_ repo: String, _ branch: String) -> String {
        "\(repo.lowercased()):\(branch)"
    }

    // MARK: - Ophalen

    /// De namen en e-mailadressen van de gebruiker. `.some(nil)`: de dienst kent ze niet; `nil`:
    /// de vraag mislukte (de branches gaan dan door zonder, de volgende ronde vraagt opnieuw).
    static func fetchIdentity(_ provider: any PRProvider) async -> UserIdentity?? {
        do {
            return .some(try await provider.currentUserIdentity())
        } catch {
            logger.notice("gebruiker ophalen voor eigen pushes mislukt: \(error.localizedDescription)")
            return nil
        }
    }

    /// Haalt de branches op van de gevolgde repo's, en bij branches als standaard van alle repo's
    /// in de lijst van de dienst (`listed` als de tag-fetch van deze poll die al ophaalde). Een
    /// bekende repo met een vingerafdruk wordt alleen helemaal opgehaald als die veranderde. Voor
    /// de veranderde heads (oud bekend, nieuw anders) volgt een vergelijking, hooguit
    /// `branchCompareLimit`, nieuwste commit eerst; een mislukte vergelijking valt weg en na een
    /// rate limit stopt het vergelijken. Gooit nooit: een fout komt in `BranchOutcome.error`.
    static func fetchBranches(
        _ provider: any PRProvider,
        _ repos: BranchRepos,
        listed: [String]? = nil,
        at now: Date = Date()
    ) async -> BranchOutcome {
        let account = repos.account
        var outcome = BranchOutcome(repos: account.branchRepos, fetch: nil, comparisons: [:], error: nil)
        do {
            if account.followsBranchesByDefault {
                let available: [String]
                if let listed {
                    available = listed
                } else {
                    available = try await provider.listRepos()
                }
                outcome.repos = account.branchRepos(available: available)
            }
            guard !outcome.repos.isEmpty else {
                outcome.fetch = BranchFetch()
                return outcome
            }
            var unchanged: [String: String] = [:]
            for repo in outcome.repos {
                // Zonder boom (van vóór de boom, of net geprunet) eenmaal helemaal lezen.
                guard repos.trees[repo.lowercased()] != nil else { continue }
                if let fingerprint = repos.known[repo.lowercased()]?.fingerprint { unchanged[repo] = fingerprint }
            }
            let fetch = try await provider.branches(in: outcome.repos, unchanged: unchanged)
            outcome.fetch = fetch
            let skipped = Set((fetch.unchangedRepos + fetch.unavailableRepos).map { $0.lowercased() })
            let changed = fetch.heads
                .compactMap { head -> (head: BranchHead, old: String)? in
                    let key = head.repo.lowercased()
                    guard !skipped.contains(key), let old = repos.known[key]?.heads[head.name], old != head.sha
                    else { return nil }
                    return (head, old)
                }
                .sorted { a, b in
                    let (da, db) = (a.head.committedAt ?? .distantPast, b.head.committedAt ?? .distantPast)
                    return da != db ? da > db : (a.head.repo, a.head.name) < (b.head.repo, b.head.name)
                }
            for (head, old) in changed.prefix(branchCompareLimit) {
                do {
                    if let comparison = try await provider.compare(in: head.repo, from: old, to: head.sha) {
                        outcome.comparisons[branchKey(head.repo, head.name)] = comparison
                    }
                } catch ProviderError.rateLimited {
                    logger.notice("branches vergelijken gestopt door rate limit")
                    break
                } catch {
                    logger.notice("branch vergelijken mislukt voor \(head.repo): \(error.localizedDescription)")
                }
            }
            let unavailable = Set(fetch.unavailableRepos.map { $0.lowercased() })
            let unchangedRepos = Set(fetch.unchangedRepos.map { $0.lowercased() })
            let headsByRepo = Dictionary(grouping: fetch.heads) { $0.repo.lowercased() }
            let defaults = Dictionary(
                fetch.defaultBranches.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            var budget = repos.treeBudget
            for repo in outcome.repos {
                let key = repo.lowercased()
                guard !unavailable.contains(key) else { continue }
                let isUnchanged = unchangedRepos.contains(key)
                guard var tree = repos.trees[key] ?? (isUnchanged ? nil : RepoBranches(accountId: account.id, repo: repo, checkedAt: Date.distantPast))
                else { continue }
                tree.repo = repo
                await updateTree(
                    &tree, heads: isUnchanged ? nil : headsByRepo[key] ?? [], defaultBranch: defaults[key],
                    pullRequests: repos.pullRequests[key] ?? [:], provider: provider, budget: &budget,
                    at: now)
                outcome.trees[key] = tree
            }
            return outcome
        } catch let error as ProviderError {
            outcome.error = error
            return outcome
        } catch {
            outcome.error = .network(error.localizedDescription)
            return outcome
        }
    }

    // MARK: - Verwerken

    /// Maakt de rijen van deze branch-poll en werkt de onthouden heads bij. Een repo die nog niet
    /// bekend is seedt: elke branch die de afgelopen `branchSeedWindow` bewoog wordt een
    /// `.recent`-rij (een datum in de toekomst telt als nu), de rest wordt alleen onthouden. Een
    /// bekende repo geeft per veranderde head een `.push` of `.forcePush` en per nieuwe branch een
    /// `.newBranch`, met als tijd `pushDate`; een verdwenen branch geeft niets. Een onbereikbare
    /// repo houdt zijn heads en geeft niets; een repo die niet meer gevolgd wordt vergeet ze, zodat aanzetten opnieuw seedt.
    /// Bij een fout verandert er niets, en na een rate limit wachten de branches tot die voorbij is.
    func handleBranches(
        _ account: Account,
        _ outcome: BranchOutcome,
        userId: String,
        identity: UserIdentity? = nil,
        provider: any PRProvider,
        retention: HistoryRetention = .oneYear,
        at t: Date
    ) -> [BranchPush] {
        if let error = outcome.error {
            var until: Date?
            if case .rateLimited(let date) = error { until = date }
            scheduleBranches(of: account, at: t, rateLimitedUntil: until)
            logger.warning("branches ophalen mislukt voor \(account.displayName): \(error.userMessage)")
            return []
        }
        scheduleBranches(of: account, at: t, rateLimitedUntil: nil)
        lastBranchCheckAt = max(lastBranchCheckAt ?? t, t)
        let wanted = Set(outcome.repos.map { $0.lowercased() })
        forgetBranchHeads(of: account, except: wanted)
        guard let fetch = outcome.fetch else { return [] }

        let prefix = "\(account.id.uuidString):"
        let unavailable = Set(fetch.unavailableRepos.map { $0.lowercased() })
        let unchanged = Set(fetch.unchangedRepos.map { $0.lowercased() })
        let fingerprints = Dictionary(
            fetch.fingerprints.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let headsByRepo = Dictionary(grouping: fetch.heads) { $0.repo.lowercased() }
        unreachable[account.id, default: UnreachableRepos()].branches =
            UnreachableRepos.names(of: outcome.repos, in: unavailable)
        if !unavailable.isEmpty {
            logger.warning("branches overgeslagen voor \(account.displayName): \(unavailable.sorted().joined(separator: ", ")) (niet gevonden of geen toegang)")
        }

        func row(_ head: BranchHead, old: String?, commits: Int?, kind: BranchPush.Kind, at date: Date) -> BranchPush {
            let compare = old.flatMap { provider.compareURL(in: head.repo, from: $0, to: head.sha) }
            return BranchPush(
                accountId: account.id, repo: head.repo, branch: head.name, oldSha: old, newSha: head.sha,
                commits: commits, kind: kind, authorName: head.authorName, authorAvatarURL: head.authorAvatarURL,
                isOwn: Self.isOwn(head, userId: userId, account: account, identity: identity), pushedAt: date,
                webURL: compare ?? head.webURL)
        }

        var pushes: [BranchPush] = []
        for repo in wanted.subtracting(unavailable) {
            let key = prefix + repo
            let known = state.branchHeads[key]
            if unchanged.contains(repo) {
                // Zonder onthouden heads is er niets om tegen te vergelijken; de volgende ronde seedt.
                state.branchHeads[key]?.seenAt = t
                continue
            }
            var heads: [String: String] = [:]
            for head in headsByRepo[repo] ?? [] where heads[head.name] == nil {
                heads[head.name] = head.sha
                if let known {
                    let date = Self.pushDate(of: head, previousRead: known.seenAt, now: t)
                    guard let old = known.heads[head.name] else {
                        pushes.append(row(head, old: nil, commits: nil, kind: .newBranch, at: date))
                        continue
                    }
                    guard old != head.sha else { continue }
                    let comparison = outcome.comparisons[Self.branchKey(head.repo, head.name)]
                    if let comparison, comparison.behind > 0 {
                        pushes.append(row(head, old: old, commits: nil, kind: .forcePush, at: date))
                    } else {
                        pushes.append(row(head, old: old, commits: comparison?.ahead, kind: .push, at: date))
                    }
                } else if let date = head.committedAt, date >= t - Self.branchSeedWindow {
                    pushes.append(row(head, old: nil, commits: nil, kind: .recent, at: min(date, t)))
                }
            }
            state.branchHeads[key] = BranchHeads(heads: heads, fingerprint: fingerprints[repo], seenAt: t)
        }
        for (repo, tree) in outcome.trees where !unavailable.contains(repo) {
            var tree = tree
            for head in headsByRepo[repo] ?? [] {
                tree.branches[head.name]?.isOwn = Self.isOwn(head, userId: userId, account: account, identity: identity)
            }
            Self.pruneRemoved(&tree, retention: retention, now: t)
            state.repoBranches[prefix + repo] = tree
        }
        return pushes
    }

    /// Wanneer een push gebeurde die deze poll zag: de datum van de nieuwste commit, maar niet
    /// vóór de vorige keer dat de repo gelezen werd (toen was de push er nog niet) en niet na nu.
    /// Zo houdt een push die pas na een slaapstand gezien wordt zijn eigen tijd. Zonder datum: nu.
    static func pushDate(of head: BranchHead, previousRead: Date, now t: Date) -> Date {
        guard let committedAt = head.committedAt else { return t }
        return min(max(committedAt, previousRead), t)
    }

    /// Vergeet de onthouden heads van de repo's (lowercased) van dit account die niet in `kept` staan.
    func forgetBranchHeads(of account: Account, except kept: Set<String>) {
        let prefix = "\(account.id.uuidString):"
        state.branchHeads = state.branchHeads.filter { key, _ in
            !key.hasPrefix(prefix) || kept.contains(String(key.dropFirst(prefix.count)))
        }
        state.repoBranches = state.repoBranches.filter { key, _ in
            !key.hasPrefix(prefix) || kept.contains(String(key.dropFirst(prefix.count)))
        }
    }

    /// Is deze branch-head van de gebruiker zelf: op account-id (`userId`), anders op het
    /// e-mailadres of de login van het account, of op een naam of e-mailadres dat de dienst van
    /// de gebruiker gaf (`identity`, bij Azure DevOps en GitLab). Alles hoofdletterongevoelig.
    static func isOwn(_ head: BranchHead, userId: String, account: Account, identity: UserIdentity? = nil) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, !a.isEmpty else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        return same(head.authorId, userId)
            || same(head.authorEmail, account.email)
            || same(head.authorId, account.login)
            || same(head.authorName, account.login)
            || (identity?.emails ?? []).contains { same(head.authorEmail, $0) }
            || (identity?.names ?? []).contains { same(head.authorName, $0) }
    }
}
