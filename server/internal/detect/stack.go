// Package detect reads language, framework and package versions out of repository files.
// It is pure text processing: no network.
package detect

import (
	"encoding/json"
	"path"
	"regexp"
	"strings"

	"github.com/alessandro823/pullwatch/server/internal/semver"
)

// MaxFiles is how many relevant files are read per repository.
const MaxFiles = 50

// Version is one language, runtime, framework or base image found in a file.
type Version struct {
	Product   string
	Label     string
	Version   string
	Source    string
	IsMinimum bool
}

var ignoredFolders = map[string]bool{
	"node_modules": true, "vendor": true, ".git": true, "bin": true,
	"obj": true, "dist": true, "build": true, ".build": true,
}

var packageFrameworks = []struct{ dep, product, label string }{
	{"@angular/core", "angular", "Angular"},
	{"react", "react", "React"},
	{"vue", "vue", "Vue"},
	{"next", "nextjs", "Next.js"},
	{"nuxt", "nuxt", "Nuxt"},
}

var composerFrameworks = []struct{ dep, product, label string }{
	{"laravel/framework", "laravel", "Laravel"},
	{"symfony/framework-bundle", "symfony", "Symfony"},
	{"symfony/http-kernel", "symfony", "Symfony"},
	{"symfony/console", "symfony", "Symfony"},
}

// LockedPackages maps a product to the lockfile package names that carry the
// installed version. That version wins over a minimum in the manifest.
var LockedPackages = map[string]map[string]bool{
	"angular": {"@angular/core": true},
	"react":   {"react": true},
	"vue":     {"vue": true},
	"nextjs":  {"next": true},
	"nuxt":    {"nuxt": true},
	"laravel": {"laravel/framework": true},
	"symfony": {"symfony/framework-bundle": true, "symfony/http-kernel": true, "symfony/console": true},
}

var dockerImages = map[string]string{
	"node": "nodejs", "golang": "go", "python": "python", "alpine": "alpine-linux",
	"debian": "debian", "ubuntu": "ubuntu", "nginx": "nginx", "postgres": "postgresql",
	"redis": "redis", "eclipse-temurin": "eclipse-temurin", "rust": "rust", "php": "php", "ruby": "ruby",
}

// Ignored reports whether path sits inside a directory that is never read.
func Ignored(p string) bool {
	parts := strings.Split(p, "/")
	if len(parts) == 0 {
		return false
	}
	for _, dir := range parts[:len(parts)-1] {
		if ignoredFolders[dir] {
			return true
		}
	}
	return false
}

// Relevant reports whether path can contain a language or framework version.
func Relevant(p string) bool {
	name := path.Base(p)
	if name == "." || name == "/" || Ignored(p) {
		return false
	}
	if p == "Cargo.toml" || isWorkflow(p) {
		return true
	}
	switch name {
	case "go.mod", "package.json", "composer.json", "Package.swift",
		"rust-toolchain", "rust-toolchain.toml", ".nvmrc", ".node-version",
		"pyproject.toml", ".python-version", "Directory.Build.props":
		return true
	}
	return strings.HasSuffix(name, ".csproj") || strings.HasSuffix(name, ".fsproj") || strings.HasPrefix(name, "Dockerfile")
}

func isWorkflow(p string) bool {
	return strings.HasPrefix(p, ".github/workflows/") && (strings.HasSuffix(p, ".yml") || strings.HasSuffix(p, ".yaml"))
}

// Detect returns versions found in one file.
func Detect(filePath, content string) []Version {
	name := path.Base(filePath)
	found := func(product, label, spec string, minimum bool) *Version {
		v, ok := semver.From(spec)
		if !ok {
			return nil
		}
		return &Version{Product: product, Label: label, Version: v, Source: filePath, IsMinimum: minimum}
	}
	one := func(v *Version) []Version {
		if v == nil {
			return nil
		}
		return []Version{*v}
	}

	switch name {
	case "go.mod":
		for _, line := range lines(content) {
			if strings.HasPrefix(line, "go ") {
				return one(found("go", "Go", strings.TrimPrefix(line, "go "), false))
			}
		}
		return nil
	case ".nvmrc", ".node-version":
		return one(found("nodejs", "Node", content, false))
	case ".python-version":
		return one(found("python", "Python", content, false))
	case "pyproject.toml":
		for _, line := range lines(content) {
			trim := strings.TrimSpace(line)
			if strings.HasPrefix(trim, "requires-python") {
				parts := strings.SplitN(trim, "=", 2)
				if len(parts) == 2 {
					return one(found("python", "Python", parts[1], true))
				}
			}
		}
		return nil
	case "package.json":
		return detectPackageJSON(content, filePath)
	case "composer.json":
		return detectComposerJSON(content, filePath)
	case "rust-toolchain":
		return one(found("rust", "Rust", content, false))
	case "rust-toolchain.toml":
		if ch := tomlString("channel", content); ch != "" {
			return one(found("rust", "Rust", ch, false))
		}
		return nil
	case "Package.swift":
		for _, line := range lines(content) {
			if strings.Contains(line, "swift-tools-version") {
				parts := strings.SplitN(line, ":", 2)
				if len(parts) == 2 {
					return one(found("swift", "Swift", parts[1], false))
				}
			}
		}
		return nil
	case "Cargo.toml":
		if v := tomlString("rust-version", content); v != "" {
			return one(found("rust", "Rust", v, true))
		}
		return nil
	default:
		if isWorkflow(filePath) {
			return detectWorkflow(content, filePath)
		}
		if strings.HasSuffix(name, ".csproj") || strings.HasSuffix(name, ".fsproj") || name == "Directory.Build.props" {
			var out []Version
			for _, v := range dotnetVersions(content) {
				out = append(out, Version{Product: "dotnet", Label: ".NET", Version: v, Source: filePath})
			}
			return out
		}
		if strings.HasPrefix(name, "Dockerfile") {
			return detectDockerfile(content, filePath)
		}
		return nil
	}
}

var (
	workflowKey = regexp.MustCompile(`^(python|node|go|dotnet)-version\s*:\s*(.*)$`)
	targetFW    = regexp.MustCompile(`<TargetFrameworks?>([^<]*)</TargetFrameworks?>`)
	netVersion  = regexp.MustCompile(`^net(\d+\.\d+)(-.*)?$`)
)

func detectWorkflow(content, filePath string) []Version {
	products := map[string][2]string{
		"python": {"python", "Python"},
		"node":   {"nodejs", "Node"},
		"go":     {"go", "Go"},
		"dotnet": {"dotnet", ".NET"},
	}
	var result []Version
	add := func(key, value string) {
		pair, ok := products[key]
		if !ok {
			return
		}
		for _, item := range splitAny(value, ",[]") {
			spec := strings.Trim(strings.TrimSpace(item), `"'`)
			spec = strings.TrimLeft(spec, "-")
			spec = strings.TrimSpace(spec)
			if strings.HasSuffix(spec, ".x") || strings.HasSuffix(spec, ".*") {
				spec = strings.TrimSuffix(strings.TrimSuffix(spec, ".x"), ".*")
			}
			if spec == "" || strings.Contains(spec, "$") {
				continue
			}
			if pair[0] == "python" && !strings.Contains(spec, ".") {
				continue
			}
			version, ok := semver.From(spec)
			if !ok || spec != version {
				continue
			}
			result = append(result, Version{Product: pair[0], Label: pair[1], Version: version, Source: filePath, IsMinimum: true})
		}
	}
	var listKey string
	for _, raw := range lines(content) {
		line := raw
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		trimmed := strings.TrimSpace(line)
		if listKey != "" && strings.HasPrefix(trimmed, "-") {
			add(listKey, strings.TrimPrefix(trimmed, "-"))
			continue
		}
		listKey = ""
		m := workflowKey.FindStringSubmatch(trimmed)
		if m == nil {
			continue
		}
		if strings.TrimSpace(m[2]) == "" {
			listKey = m[1]
		} else {
			add(m[1], m[2])
		}
	}
	return result
}

func detectPackageJSON(content, filePath string) []Version {
	var pkg struct {
		Engines         map[string]string `json:"engines"`
		Dependencies    map[string]string `json:"dependencies"`
		DevDependencies map[string]string `json:"devDependencies"`
	}
	if err := json.Unmarshal([]byte(content), &pkg); err != nil {
		return nil
	}
	var result []Version
	if node, ok := pkg.Engines["node"]; ok {
		if v, ok := semver.From(node); ok {
			result = append(result, Version{Product: "nodejs", Label: "Node", Version: v, Source: filePath, IsMinimum: true})
		}
	}
	deps := map[string]string{}
	for k, v := range pkg.DevDependencies {
		deps[k] = v
	}
	for k, v := range pkg.Dependencies {
		deps[k] = v
	}
	for _, fw := range packageFrameworks {
		if spec, ok := deps[fw.dep]; ok {
			if v, ok := semver.From(spec); ok {
				result = append(result, Version{Product: fw.product, Label: fw.label, Version: v, Source: filePath})
			}
		}
	}
	return result
}

func detectComposerJSON(content, filePath string) []Version {
	var doc struct {
		Require map[string]string `json:"require"`
	}
	if err := json.Unmarshal([]byte(content), &doc); err != nil {
		return nil
	}
	var result []Version
	if php, ok := doc.Require["php"]; ok {
		if v, ok := semver.From(php); ok {
			result = append(result, Version{Product: "php", Label: "PHP", Version: v, Source: filePath, IsMinimum: true})
		}
	}
	seen := map[string]bool{}
	for _, fw := range composerFrameworks {
		if seen[fw.product] {
			continue
		}
		if spec, ok := doc.Require[fw.dep]; ok {
			if v, ok := semver.From(spec); ok {
				seen[fw.product] = true
				result = append(result, Version{Product: fw.product, Label: fw.label, Version: v, Source: filePath})
			}
		}
	}
	return result
}

// LocalGoReplacements returns directories (from the repo root) of modules
// pulled in with `replace … => ./path`. Those go.mod files are vendored
// copies; their go line is a minimum, not the build version.
func LocalGoReplacements(filePath, content string) []string {
	base := strings.Split(filePath, "/")
	if len(base) > 0 {
		base = base[:len(base)-1]
	}
	var out []string
	for _, line := range lines(content) {
		idx := strings.Index(line, "=>")
		if idx < 0 {
			continue
		}
		rest := strings.TrimSpace(line[idx+2:])
		target := rest
		if i := strings.IndexAny(rest, " \t"); i >= 0 {
			target = rest[:i]
		}
		if !strings.HasPrefix(target, "./") && !strings.HasPrefix(target, "../") {
			continue
		}
		parts := append([]string{}, base...)
		for _, c := range strings.Split(target, "/") {
			switch c {
			case "", ".":
			case "..":
				if len(parts) > 0 {
					parts = parts[:len(parts)-1]
				}
			default:
				parts = append(parts, c)
			}
		}
		out = append(out, strings.Join(parts, "/"))
	}
	return out
}

func tomlString(key, content string) string {
	for _, line := range lines(content) {
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		if strings.TrimSpace(parts[0]) != key {
			continue
		}
		return strings.Trim(strings.TrimSpace(parts[1]), `"'`)
	}
	return ""
}

func dotnetVersions(content string) []string {
	var versions []string
	for _, m := range targetFW.FindAllStringSubmatch(content, -1) {
		for _, framework := range strings.Split(m[1], ";") {
			value := strings.TrimSpace(framework)
			sm := netVersion.FindStringSubmatch(value)
			if sm == nil {
				continue
			}
			if !contains(versions, sm[1]) {
				versions = append(versions, sm[1])
			}
		}
	}
	return versions
}

func detectDockerfile(content, filePath string) []Version {
	var result []Version
	args := map[string]string{}
	for _, line := range lines(content) {
		words := strings.Fields(line)
		filtered := words[:0]
		for _, w := range words {
			if !strings.HasPrefix(w, "--") {
				filtered = append(filtered, w)
			}
		}
		words = filtered
		if len(words) >= 2 && strings.EqualFold(words[0], "ARG") {
			parts := strings.SplitN(words[1], "=", 2)
			if len(parts) == 2 {
				args[parts[0]] = strings.Trim(parts[1], `"'`)
			}
			continue
		}
		if len(words) < 2 || !strings.EqualFold(words[0], "FROM") {
			continue
		}
		reference := words[1]
		// ${NAME} before $NAME, so the braced form is not left half-substituted.
		var names []string
		for name := range args {
			names = append(names, name)
		}
		sortLongest(names)
		for _, name := range names {
			reference = strings.ReplaceAll(reference, "${"+name+"}", args[name])
			reference = strings.ReplaceAll(reference, "$"+name, args[name])
		}
		if at := strings.IndexByte(reference, '@'); at >= 0 {
			reference = reference[:at]
		}
		if strings.Contains(reference, "$") {
			continue
		}
		colon := strings.LastIndexByte(reference, ':')
		if colon < 0 {
			continue
		}
		image := reference[:colon]
		tag := reference[colon+1:]
		imageName := image
		if i := strings.LastIndexByte(image, '/'); i >= 0 {
			imageName = image[i+1:]
		}
		knownPrefix := ""
		if dash := strings.IndexByte(imageName, '-'); dash > 0 {
			prefix := imageName[:dash]
			if _, ok := dockerImages[prefix]; ok {
				knownPrefix = prefix
			}
		}
		shortName := imageName
		switch {
		case strings.HasPrefix(image, "mcr.microsoft.com/dotnet/"):
			shortName = "dotnet"
		case dockerImages[imageName] != "":
			shortName = imageName
		case knownPrefix != "":
			shortName = knownPrefix
		}
		product := ""
		if shortName == "dotnet" {
			product = "dotnet"
		} else {
			product = dockerImages[shortName]
		}
		if product == "" {
			continue
		}
		v, ok := semver.From(tag)
		if !ok {
			continue
		}
		result = append(result, Version{Product: product, Label: "Docker " + shortName, Version: v, Source: filePath})
	}
	return result
}

func lines(content string) []string {
	return strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
}

func splitAny(s, chars string) []string {
	return strings.FieldsFunc(s, func(r rune) bool {
		return strings.ContainsRune(chars, r)
	})
}

func contains(ss []string, v string) bool {
	for _, s := range ss {
		if s == v {
			return true
		}
	}
	return false
}

func sortLongest(ss []string) {
	for i := 1; i < len(ss); i++ {
		j := i
		for j > 0 && len(ss[j]) > len(ss[j-1]) {
			ss[j], ss[j-1] = ss[j-1], ss[j]
			j--
		}
	}
}
