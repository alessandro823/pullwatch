# The Pullwatch website

The landing page and the user documentation, built with
[Astro Starlight](https://starlight.astro.build) and deployed to GitHub Pages
by `.github/workflows/site.yml`. The address and the custom domain are in
[docs/website.md](../docs/website.md).

## Run it

You need the Node version in `.nvmrc` (with nvm: `nvm use`).

```sh
cd site
npm ci --ignore-scripts   # the exact versions of package-lock.json, no install scripts
npm run dev               # http://localhost:4321/pullwatch/, reloads on every change
```

Astro's telemetry is off in CI; turn it off on your Mac too with
`npx astro telemetry disable` or `ASTRO_TELEMETRY_DISABLED=1`.

## Build and check it

```sh
npm run build          # dist/, with the Pagefind search index; fails on a broken Markdown link
npm run check-links    # follows every internal href, src and srcset in dist/
npm run preview        # serves dist/ as GitHub Pages would, search included
```

`npm run build` builds for the project page,
`https://alessandro823.github.io/pullwatch/` (base `/pullwatch/`). With
`PAGES_DOMAIN=pullwatch.net npm run build` it builds for
`https://pullwatch.net/` (base `/`); run `check-links` with the same variable.
CI builds and checks both.

## Add a page

1. Add a Markdown file under `src/content/docs/`, such as
   `src/content/docs/using/history.md`; its path is its address
   (`/using/history/`). Use `.mdx` when the page shows a screenshot.
2. Give it a `title` and a one-sentence `description` in the front matter.
3. Add it to the `sidebar` in `astro.config.mjs`, by its `slug`
   (`using/history`).
4. Link to other pages from the site root: `[Notifications](/using/notifications/)`.
   `src/plugins/base-links.mjs` adds `/pullwatch` on the project page, and the
   links validator fails the build when the page does not exist.
   In a component, build a link with `import.meta.env.BASE_URL`.
5. Add the same page in Dutch, German and French under
   `src/content/docs/nl/`, `de/` and `fr/` (see [Languages](#languages)).
6. Add its slug to `order` in `src/llms.ts`, at the same place as in the
   sidebar, so `llms.txt` and `llms-full.txt` list it.

Write as the other pages do: English, short sentences, the names the app
shows (**Settings**, **Sources**), and only what the code does. No em dashes,
no middle dots.

## Search engines and AI assistants

- `robots.txt` (`src/pages/robots.txt.ts`) lets every crawler in and names
  the sitemap that Starlight writes.
- `llms.txt` and `llms-full.txt` (`src/pages/`, with `src/llms.ts`) give AI
  assistants what Pullwatch is, a link per English page, and every English
  page as Markdown in one file (<https://llmstxt.org/>).
- `src/structuredData.ts`, Starlight route middleware, adds schema.org
  JSON-LD: a `SoftwareApplication` on each landing page (version from
  `Pullwatch/App.xcconfig`) and a `FAQPage` from the `##` questions of each
  FAQ page.
- After each deploy, `site.yml` sends every URL in the sitemap to IndexNow
  (Bing, Yandex, Seznam, Naver). The key is the file
  `public/2d23b6c65e81c2975e13d39327232aa3.txt`; a new key means a new file
  and the same value in `site.yml`.
- Each landing page sets its own `<title>`, `og:title` and `og:type` in its
  front matter `head`; every other page gets `<title>` and the description
  from its front matter.

## Screenshots

`src/assets/screenshots/light/` and `dark/` hold the English set, and
`src/assets/screenshots/<lang>/light/` and `dark/` the set of each other
language, all with the same file names. Show one with the `Screenshot`
component, which picks the one for the page's language and the reader's
theme and lets Astro make AVIF and WebP in a few sizes:

```mdx
import Screenshot from '../../../components/Screenshot.astro';

<Screenshot name="repo-check" alt="What the screenshot shows, in words." />
```

Every screenshot comes from the app's own camera tour with fake data, never
from a real account. Build a debug app and run it from the build folder
(not `/Applications`), with a data folder that holds a `config.json` with one
GitHub account:

```sh
Pullwatch.app/Contents/MacOS/Pullwatch -PullwatchDataDirectory <data> \
  -PullwatchFakeGitHub YES -PullwatchFakeData YES -PullwatchFakeGitHubInstalled YES \
  -PullwatchSnapshotTour YES -PullwatchSnapshotDirectory <shots> \
  -PullwatchSnapshotLight YES -AppleLanguages '(en)'
```

Run it again with `-PullwatchSnapshotDark YES -AppleInterfaceStyle Dark` for
the dark set, and with `-PullwatchMenuPreview YES` and
`-PullwatchNotificationPreview YES -PullwatchSkipNotificationRequest YES` (on
the same data folder, so the menu has content) for the menu panel and the
notifications. The main window draws its sidebar empty, so crop the shots
to the content to the right of it, at 2x. For another language, pass
`-AppleLanguages '(nl)' -AppleLocale nl_NL` (or `de`, `fr`). A window that
opens on a 1x display is drawn at 1x: take that run again, or pin the
window to the built-in display through the argument domain, such as
`"-NSWindow Frame main" "60 200 1360 572 0 0 1512 949 "`.

The site's set uses a `config.json` with two GitHub accounts: `octocat`
following `octocat/hello-world`, `octocat/spoon-knife`, `octocat/linguist`
and the extra repository `openEHR/specifications-AM`, and a second account
for the owner `github` following `github/docs`. The fake `github`
organisation always answers 403 on its packages, so Packages shows the line
that one account has no access to its package registry. The fake octocat
publishes one package per followed repository (npm `greeting`, used by
hello-world as the in-house `@octocat/greeting`, a container image and a
NuGet package) plus `shared-config` without a repository. For the empty
states of Packages, `-PullwatchFakePackages forbidden` makes octocat's
registry answer 403 and `-PullwatchFakePackages none` publish nothing. The
tour shoots `packages`, `packages-inspector` and `packages-repo` (Packages
filtered on one repository). `-PullwatchOnboardingTour YES` on an empty
data folder walks the welcome window instead (`onboarding-account` is the
choice of service).

## Languages

English is the root locale (no `/en/` in the address) and the fallback.
Dutch (`nl`), German (`de`) and French (`fr`) are in `astro.config.mjs` under
`locales`, with their pages in `src/content/docs/<lang>/` under the same
paths as the English ones, so the language picker and the `hreflang` links go
from page to page. Every page exists in every language: the links validator
fails the build on a link to an untranslated (fallback) page or to a page in
another language.

- A link on a translated page carries its language: `/nl/using/menu/`, and a
  `#heading` is the slug of the translated heading.
- The text of the landing page's own components is in
  `src/content/i18n/<lang>.json` (the `pw.*` keys, read with
  `Astro.locals.t`); `nl.json` also fills two Starlight strings its Dutch
  lacks.
- Every name of a button, menu, tab or setting is the one the app shows in
  that language, from the String Catalogs (`Localizable.xcstrings`; the key
  is the Dutch, the values per language). `python3 scripts/check-terms.py`
  lists each bold or code name per language and fails on one the catalogs do
  not hold, unless it is on its list of outside names (macOS, the services)
  or emphasis.
- Dutch says "je", German "du" and French "vous", as the app does.
