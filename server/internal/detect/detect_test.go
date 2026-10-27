package detect

import (
	"strings"
	"testing"
)

func TestRelevantPaths(t *testing.T) {
	for _, path := range []string{"go.mod", "src/Api/Api.csproj", "Directory.Build.props", "deploy/Dockerfile.prod", "web/package.json", "Cargo.toml", ".github/workflows/ci.yml"} {
		if !Relevant(path) {
			t.Errorf("expected relevant: %s", path)
		}
	}
	for _, path := range []string{"node_modules/react/package.json", "src/bin/Debug/x.csproj", "README.md", "lib/Cargo.toml"} {
		if Relevant(path) {
			t.Errorf("expected ignored: %s", path)
		}
	}
}

func TestDetectsLanguagesAndImages(t *testing.T) {
	goMod := Detect("go.mod", "module x\n\ngo 1.23.4\n\ntoolchain go1.24.1\n")
	if len(goMod) != 1 || goMod[0].Version != "1.23.4" || goMod[0].Product != "go" {
		t.Fatalf("go.mod: %+v", goMod)
	}
	xml := "<Project><PropertyGroup><TargetFrameworks>netstandard2.0;net8.0;net9.0-windows</TargetFrameworks></PropertyGroup></Project>"
	dotnet := Detect("src/A/A.csproj", xml)
	if len(dotnet) != 2 || dotnet[0].Version != "8.0" || dotnet[1].Version != "9.0" {
		t.Fatalf(".NET: %+v", dotnet)
	}
	if len(Detect("A.csproj", "<TargetFramework>net48</TargetFramework>")) != 0 {
		t.Fatal("net48 is not a modern TFM")
	}
	pkg := Detect("package.json", `{"engines":{"node":">=20.10"},"dependencies":{"@angular/core":"^17.2.0","rxjs":"7"},"devDependencies":{"react":"~18.3.1"}}`)
	got := map[string]bool{}
	for _, v := range pkg {
		got[v.Product+"@"+v.Version] = true
		if v.Product == "nodejs" && !v.IsMinimum {
			t.Fatal("engines.node is a minimum")
		}
	}
	for _, want := range []string{"nodejs@20.10", "angular@17.2.0", "react@18.3.1"} {
		if !got[want] {
			t.Errorf("missing %s in %+v", want, pkg)
		}
	}
	if Detect(".nvmrc", "v20.11.0\n")[0].Version != "20.11.0" || len(Detect(".nvmrc", "lts/*\n")) != 0 {
		t.Fatal("nvmrc")
	}
	if Detect("pyproject.toml", "[project]\nrequires-python = \">=3.11\"\n")[0].Version != "3.11" {
		t.Fatal("python")
	}
	docker := Detect("Dockerfile", "ARG GO=1.22\nFROM golang:${GO} AS build\nFROM --platform=linux/amd64 node:20-alpine AS web\nFROM mcr.microsoft.com/dotnet/aspnet:8.0\nFROM python:latest\nFROM scratch\n")
	var labels []string
	for _, v := range docker {
		labels = append(labels, v.Label+"@"+v.Version)
	}
	if strings.Join(labels, ",") != "Docker golang@1.22,Docker node@20,Docker dotnet@8.0" {
		t.Fatalf("dockerfile: %s", labels)
	}
	if Detect("Dockerfile", "FROM php-fpm-alpine:8.4\n")[0].Product != "php" {
		t.Fatal("custom image prefix")
	}
	if len(LocalGoReplacements("cmd/go.mod", "replace example.com/c => ../c\nreplace example.com/d => ./d\n")) != 2 {
		t.Fatal("local replacements")
	}
	wf := Detect(".github/workflows/ci.yml", "jobs:\n  test:\n    strategy:\n      matrix:\n        python-version:\n          - \"3.11\"\n          - 3.x\n        node-version: 20.x\n")
	found := map[string]bool{}
	for _, v := range wf {
		found[v.Product+"@"+v.Version] = v.IsMinimum
	}
	if !found["python@3.11"] || found["python@3"] || !found["nodejs@20"] {
		t.Fatalf("workflow: %+v", wf)
	}
}

func TestDependencies(t *testing.T) {
	gomod := `
module x
go 1.26
require github.com/a/b v1.2.3
require (
    golang.org/x/net v0.17.0 // indirect
    example.com/local v0.0.0-20240101-abcdef
)
replace example.com/c => ../c
`
	names := func(deps []Dependency) string {
		var b strings.Builder
		for i, d := range deps {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(d.Name + "@" + d.Version)
		}
		return b.String()
	}
	if got := names(Dependencies("go.mod", gomod)); got != "github.com/a/b@1.2.3,golang.org/x/net@0.17.0,example.com/local@0.0.0-20240101-abcdef" {
		t.Fatal(got)
	}
	lock := `{"lockfileVersion":3,"packages":{
      "":{"version":"1.0.0"},
      "node_modules/lodash":{"version":"4.17.20"},
      "node_modules/a/node_modules/@scope/b":{"version":"2.0.0"},
      "node_modules/local":{"version":"file:../local"}
    }}`
	if got := names(Dependencies("package-lock.json", lock)); got != "@scope/b@2.0.0,lodash@4.17.20" {
		t.Fatal(got)
	}
	if got := names(Dependencies("package-lock.json", `{"lockfileVersion":1,"dependencies":{"lodash":{"version":"4.17.20"}}}`)); got != "lodash@4.17.20" {
		t.Fatal(got)
	}
	xml := `<ItemGroup>
      <PackageReference Include="Newtonsoft.Json" Version="12.0.1" />
      <PackageReference Version="6.0.0" Include="Serilog"></PackageReference>
      <PackageVersion Include="Polly" Version="7.2.4" />
      <PackageReference Include="Floating" Version="1.*" />
      <PackageReference Include="Central" />
    </ItemGroup>`
	if got := names(Dependencies("src/A.csproj", xml)); got != "Newtonsoft.Json@12.0.1,Serilog@6.0.0,Polly@7.2.4" {
		t.Fatal(got)
	}
	req := "# comment\nDjango==4.2.1\nrequests[security] == 2.31.0 ; python_version > \"3.8\"\nflask>=2\n-r other.txt\n"
	if got := names(Dependencies("requirements-dev.txt", req)); got != "Django@4.2.1,requests@2.31.0" {
		t.Fatal(got)
	}
	poetry := "[[package]]\nname = \"jinja2\"\nversion = \"3.1.2\"\n\n[package.dependencies]\nmarkupsafe = \">=2.0\"\n\n[[package]]\nname = \"markupsafe\"\nversion = \"2.1.3\"\n"
	if got := names(Dependencies("poetry.lock", poetry)); got != "jinja2@3.1.2,markupsafe@2.1.3" {
		t.Fatal(got)
	}
	if !DepRelevant("uv.lock") || DepRelevant("yarn.lock") {
		t.Fatal("lockfile selection")
	}
	cargo := "[[package]]\nname = \"libc\"\nversion = \"0.2.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n\n[[package]]\nname = \"local\"\nversion = \"0.1.0\"\n"
	got := Dependencies("Cargo.lock", cargo)
	if len(got) != 1 || got[0].Name != "libc" || got[0].Ecosystem != "crates.io" {
		t.Fatalf("cargo: %+v", got)
	}
	if SwiftPackageName("git@github.com:apple/swift-nio.git") != "github.com/apple/swift-nio" {
		t.Fatal("swift package name")
	}
}
