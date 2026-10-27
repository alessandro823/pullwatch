package detect

import (
	"encoding/json"
	"path"
	"regexp"
	"strings"

	"github.com/alessandro823/pullwatch/server/internal/semver"
)

// Dependency is a package at an exact version, in OSV's terms.
type Dependency struct {
	Ecosystem string
	Name      string
	Version   string
	Source    string
}

// WithoutSource is the key used to query OSV once per package version.
func (d Dependency) WithoutSource() Dependency {
	d.Source = ""
	return d
}

// DepRelevant reports whether path can contain exact package versions.
// yarn.lock and pnpm-lock.yaml are intentionally not read.
func DepRelevant(p string) bool {
	name := path.Base(p)
	if name == "." || name == "/" {
		return false
	}
	switch name {
	case "go.mod", "package-lock.json", "Package.resolved", "composer.lock",
		"Cargo.lock", "poetry.lock", "uv.lock", "Directory.Packages.props", "Directory.Build.props":
		return true
	}
	if strings.HasSuffix(name, ".csproj") || strings.HasSuffix(name, ".fsproj") {
		return true
	}
	return strings.HasPrefix(name, "requirements") && strings.HasSuffix(name, ".txt")
}

// Dependencies returns packages with an exact version. Ranges are skipped;
// OSV needs an exact version.
func Dependencies(filePath, content string) []Dependency {
	name := path.Base(filePath)
	switch name {
	case "go.mod":
		return goModules(content, filePath)
	case "package-lock.json":
		return npmLock(content, filePath)
	case "composer.lock":
		return composerLock(content, filePath)
	case "Package.resolved":
		return swiftPackages(content, filePath)
	case "poetry.lock", "uv.lock":
		return tomlLock(content, filePath, "PyPI", false)
	case "Cargo.lock":
		return tomlLock(content, filePath, "crates.io", true)
	default:
		if strings.HasPrefix(name, "requirements") {
			return requirements(content, filePath)
		}
		return nugetPackages(content, filePath)
	}
}

func goModules(content, filePath string) []Dependency {
	var result []Dependency
	inBlock := false
	for _, raw := range lines(content) {
		line := raw
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "require (" {
			inBlock = true
			continue
		}
		if inBlock && line == ")" {
			inBlock = false
			continue
		}
		if strings.HasPrefix(line, "require ") {
			line = strings.TrimPrefix(line, "require ")
		} else if !inBlock {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) != 2 || !strings.HasPrefix(parts[1], "v") {
			continue
		}
		result = append(result, Dependency{
			Ecosystem: "Go", Name: parts[0], Version: strings.TrimPrefix(parts[1], "v"), Source: filePath,
		})
	}
	return result
}

func npmLock(content, filePath string) []Dependency {
	var lock struct {
		Packages map[string]struct {
			Version string `json:"version"`
		} `json:"packages"`
		Dependencies map[string]struct {
			Version string `json:"version"`
		} `json:"dependencies"`
	}
	if err := json.Unmarshal([]byte(content), &lock); err != nil {
		return nil
	}
	seen := map[string]bool{}
	var result []Dependency
	add := func(name, version string) {
		if name == "" || version == "" {
			return
		}
		if _, ok := semver.From(version); !ok || strings.Contains(version, ":") {
			return
		}
		key := name + "@" + version
		if seen[key] {
			return
		}
		seen[key] = true
		result = append(result, Dependency{Ecosystem: "npm", Name: name, Version: version, Source: filePath})
	}
	if lock.Packages != nil {
		for key, entry := range lock.Packages {
			idx := strings.LastIndex(key, "node_modules/")
			if idx < 0 {
				continue
			}
			add(key[idx+len("node_modules/"):], entry.Version)
		}
	} else {
		for name, entry := range lock.Dependencies {
			add(name, entry.Version)
		}
	}
	sortDeps(result)
	return result
}

func composerLock(content, filePath string) []Dependency {
	var lock struct {
		Packages []struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"packages"`
		PackagesDev []struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"packages-dev"`
	}
	if err := json.Unmarshal([]byte(content), &lock); err != nil {
		return nil
	}
	var result []Dependency
	all := append(lock.Packages, lock.PackagesDev...)
	for _, pkg := range all {
		if strings.HasPrefix(pkg.Version, "dev-") {
			continue
		}
		version := pkg.Version
		if strings.HasPrefix(version, "v") {
			version = version[1:]
		}
		if _, ok := semver.From(version); !ok {
			continue
		}
		result = append(result, Dependency{Ecosystem: "Packagist", Name: pkg.Name, Version: version, Source: filePath})
	}
	return result
}

func swiftPackages(content, filePath string) []Dependency {
	var resolved struct {
		Pins   []swiftPin `json:"pins"`
		Object *struct {
			Pins []swiftPin `json:"pins"`
		} `json:"object"`
	}
	if err := json.Unmarshal([]byte(content), &resolved); err != nil {
		return nil
	}
	pins := resolved.Pins
	if pins == nil && resolved.Object != nil {
		pins = resolved.Object.Pins
	}
	var result []Dependency
	for _, pin := range pins {
		rawURL := pin.Location
		if rawURL == "" {
			rawURL = pin.RepositoryURL
		}
		if rawURL == "" || pin.State.Version == "" {
			continue
		}
		result = append(result, Dependency{
			Ecosystem: "SwiftURL", Name: SwiftPackageName(rawURL), Version: pin.State.Version, Source: filePath,
		})
	}
	return result
}

type swiftPin struct {
	Location      string `json:"location"`
	RepositoryURL string `json:"repositoryURL"`
	State         struct {
		Version string `json:"version"`
	} `json:"state"`
}

// SwiftPackageName turns a git URL into the OSV SwiftURL name:
// "https://github.com/apple/swift-nio.git" → "github.com/apple/swift-nio".
func SwiftPackageName(raw string) string {
	name := raw
	if i := strings.Index(name, "://"); i >= 0 {
		name = name[i+3:]
	}
	if strings.HasPrefix(name, "git@") {
		name = strings.TrimPrefix(name, "git@")
		name = strings.Replace(name, ":", "/", 1)
	}
	name = strings.TrimSuffix(name, ".git")
	name = strings.TrimSuffix(name, "/")
	return name
}

var tomlField = regexp.MustCompile(`^(name|version)\s*=\s*"([^"]+)"`)

func tomlLock(content, filePath, ecosystem string, registryOnly bool) []Dependency {
	var result []Dependency
	var name, version string
	fromRegistry := false
	flush := func() {
		if name != "" && version != "" && (!registryOnly || fromRegistry) {
			result = append(result, Dependency{Ecosystem: ecosystem, Name: name, Version: version, Source: filePath})
		}
		name, version = "", ""
		fromRegistry = false
	}
	for _, raw := range lines(content) {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") {
			flush()
			continue
		}
		if strings.HasPrefix(line, `source = "registry+`) {
			fromRegistry = true
		}
		m := tomlField.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if m[1] == "name" {
			if name == "" {
				name = m[2]
			}
		} else if version == "" {
			version = m[2]
		}
	}
	flush()
	return result
}

var requirementPin = regexp.MustCompile(`^([A-Za-z0-9._-]+)(\[[^\]]*\])?\s*==\s*([^\s,]+)`)

func requirements(content, filePath string) []Dependency {
	var result []Dependency
	for _, raw := range lines(content) {
		line := raw
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		spec := line
		if i := strings.IndexByte(spec, ';'); i >= 0 {
			spec = spec[:i]
		}
		m := requirementPin.FindStringSubmatch(strings.TrimSpace(spec))
		if m == nil {
			continue
		}
		result = append(result, Dependency{Ecosystem: "PyPI", Name: m[1], Version: m[3], Source: filePath})
	}
	return result
}

var (
	nugetTag     = regexp.MustCompile(`<Package(?:Reference|Version)\b([^>]*)>`)
	nugetInclude = regexp.MustCompile(`Include="([^"]+)"`)
	nugetVersion = regexp.MustCompile(`Version="([^"$\[\]()*]+)"`)
)

func nugetPackages(content, filePath string) []Dependency {
	var result []Dependency
	for _, m := range nugetTag.FindAllStringSubmatch(content, -1) {
		inc := nugetInclude.FindStringSubmatch(m[1])
		ver := nugetVersion.FindStringSubmatch(m[1])
		if inc == nil || ver == nil {
			continue
		}
		result = append(result, Dependency{Ecosystem: "NuGet", Name: inc[1], Version: ver[1], Source: filePath})
	}
	return result
}

func sortDeps(ds []Dependency) {
	for i := 1; i < len(ds); i++ {
		j := i
		for j > 0 && (ds[j].Name < ds[j-1].Name || (ds[j].Name == ds[j-1].Name && ds[j].Version < ds[j-1].Version)) {
			ds[j], ds[j-1] = ds[j-1], ds[j]
			j--
		}
	}
}
