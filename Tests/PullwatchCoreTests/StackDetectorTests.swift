import Foundation
import Testing
@testable import PullwatchCore

@Suite struct StackDetectorTests {
    @Test func selectsRelevantPathsOutsideIgnoredFolders() {
        #expect(StackDetector.isRelevant("go.mod"))
        #expect(StackDetector.isRelevant("src/Api/Api.csproj"))
        #expect(StackDetector.isRelevant("Directory.Build.props"))
        #expect(StackDetector.isRelevant("deploy/Dockerfile.prod"))
        #expect(StackDetector.isRelevant("web/package.json"))
        #expect(!StackDetector.isRelevant("node_modules/react/package.json"))
        #expect(!StackDetector.isRelevant("src/bin/Debug/x.csproj"))
        #expect(!StackDetector.isRelevant("README.md"))
    }

    @Test func readsGoDirective() {
        let found = StackDetector.detect(path: "go.mod", content: "module x\n\ngo 1.23.4\n\ntoolchain go1.24.1\n")
        #expect(found == [DetectedVersion(product: "go", label: "Go", version: "1.23.4", source: "go.mod")])
    }

    @Test func readsDotnetTargetFrameworks() {
        let xml = """
        <Project><PropertyGroup>
          <TargetFrameworks>netstandard2.0;net8.0;net9.0-windows</TargetFrameworks>
        </PropertyGroup></Project>
        """
        let found = StackDetector.detect(path: "src/A/A.csproj", content: xml)
        #expect(found.map(\.version) == ["8.0", "9.0"])
        #expect(found.allSatisfy { $0.product == "dotnet" && $0.label == ".NET" })
    }

    @Test func skipsDotnetFramework() {
        let xml = "<TargetFramework>net48</TargetFramework>"
        #expect(StackDetector.detect(path: "A.csproj", content: xml).isEmpty)
    }

    @Test func readsPackageJson() {
        let json = """
        {"engines":{"node":">=20.10"},
         "dependencies":{"@angular/core":"^17.2.0","rxjs":"7"},
         "devDependencies":{"react":"~18.3.1"}}
        """
        let found = StackDetector.detect(path: "package.json", content: json)
        #expect(Set(found.map { "\($0.product)@\($0.version)" }) == ["nodejs@20.10", "angular@17.2.0", "react@18.3.1"])
    }

    @Test func readsNvmrcAndSkipsAliases() {
        #expect(StackDetector.detect(path: ".nvmrc", content: "v20.11.0\n").first?.version == "20.11.0")
        #expect(StackDetector.detect(path: ".nvmrc", content: "lts/*\n").isEmpty)
    }

    @Test func readsPython() {
        #expect(StackDetector.detect(path: "pyproject.toml", content: "[project]\nrequires-python = \">=3.11\"\n").first?.version == "3.11")
        #expect(StackDetector.detect(path: ".python-version", content: "3.12.1\n").first?.version == "3.12.1")
    }

    @Test func readsDockerfileBaseImages() {
        let dockerfile = """
        ARG GO=1.22
        FROM golang:${GO} AS build
        FROM --platform=linux/amd64 node:20-alpine AS web
        FROM mcr.microsoft.com/dotnet/aspnet:8.0
        FROM python:latest
        FROM scratch
        """
        let found = StackDetector.detect(path: "Dockerfile", content: dockerfile)
        #expect(found.map { "\($0.label)@\($0.version)" } == ["Docker golang@1.22", "Docker node@20", "Docker dotnet@8.0"])
        #expect(found.map(\.product) == ["go", "nodejs", "dotnet"])
    }

    @Test func extractsVersionFromSpec() {
        #expect(StackDetector.version(from: "^17.2.0") == "17.2.0")
        #expect(StackDetector.version(from: ">= 3.11, <4") == "3.11")
        #expect(StackDetector.version(from: "20-alpine") == "20")
        #expect(StackDetector.version(from: "latest") == nil)
    }
}

@Suite struct EndOfLifeTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000) // okt 2026

    func releases() -> [EndOfLifeRelease] {
        [
            EndOfLifeRelease(name: "1.28", releaseDate: "2027-02-01", isEol: false, latest: "1.28.0"),
            EndOfLifeRelease(name: "1.27", releaseDate: "2026-08-19", isEol: false, latest: "1.27.3"),
            EndOfLifeRelease(name: "1.26", releaseDate: "2026-02-10", isEol: false, latest: "1.26.10"),
            EndOfLifeRelease(name: "1.25", releaseDate: "2025-08-12", isEol: true, latest: "1.25.9"),
        ]
    }

    @Test func currentWhenOnNewestReleasedCycleEvenWithOldPatch() {
        let result = EndOfLife.evaluate(version: "1.27.1", releases: releases(), now: now)
        #expect(result.status == .current)
        #expect(result.latest == "1.27.3")
    }

    @Test func behindWhenNewerCycleExists() {
        let result = EndOfLife.evaluate(version: "1.26", releases: releases(), now: now)
        #expect(result.status == .behind)
        #expect(result.latest == "1.27.3")
    }

    @Test func eolWins() {
        #expect(EndOfLife.evaluate(version: "1.25.0", releases: releases(), now: now).status == .eol)
    }

    @Test func unknownWithoutMatchingCycle() {
        #expect(EndOfLife.evaluate(version: "2.0", releases: releases(), now: now).status == .unknown)
    }

    @Test func matchesLongestCycleAndMajorOnlyCycles() {
        let dotnet = [
            EndOfLifeRelease(name: "10", releaseDate: "2025-11-11", isEol: false, latest: "10.0.3"),
            EndOfLifeRelease(name: "8", releaseDate: "2023-11-14", isEol: false, latest: "8.0.20"),
        ]
        #expect(EndOfLife.evaluate(version: "8.0", releases: dotnet, now: now).status == .behind)
        #expect(EndOfLife.evaluate(version: "10.0", releases: dotnet, now: now).status == .current)
        // "1" mag niet matchen op "10".
        #expect(EndOfLife.evaluate(version: "1.0", releases: dotnet, now: now).status == .unknown)
    }

    @Test func decodesApiResponse() throws {
        let body = #"""
        {"result":{"name":"go","releases":[
          {"name":"1.27","releaseDate":"2026-08-19","isEol":false,"latest":{"name":"1.27.3","date":"2026-10-19"}},
          {"name":"1.0","releaseDate":"2012-03-28","isEol":true,"latest":null}
        ]}}
        """#
        let list = try EndOfLife.decode(Data(body.utf8))
        #expect(list == [
            EndOfLifeRelease(name: "1.27", releaseDate: "2026-08-19", isEol: false, latest: "1.27.3"),
            EndOfLifeRelease(name: "1.0", releaseDate: "2012-03-28", isEol: true, latest: nil),
        ])
    }
}

@Suite struct PHPDetectionTests {
    @Test func readsComposerJSON() {
        let json = """
        {"require":{"php":"^8.4","ext-json":"*","symfony/console":"^7.2","slim/slim":"^4.12"},
         "require-dev":{"phpunit/phpunit":"^11.5"}}
        """
        #expect(StackDetector.isRelevant("composer.json"))
        let found = StackDetector.detect(path: "composer.json", content: json)
        #expect(found.map { "\($0.product)@\($0.version)" } == ["php@8.4", "symfony@7.2"])
        #expect(found.map(\.label) == ["PHP", "Symfony"])
    }

    @Test func readsLaravel() {
        let found = StackDetector.detect(path: "composer.json", content: #"{"require":{"laravel/framework":"^11.0"}}"#)
        #expect(found.map { "\($0.product)@\($0.version)" } == ["laravel@11.0"])
    }

    @Test func recognisesCustomImageByKnownPrefix() {
        let dockerfile = "FROM registry.example.com/docker/php-fpm-alpine-custom:8.4 AS base\nFROM base AS dev\n"
        let found = StackDetector.detect(path: "Dockerfile", content: dockerfile)
        #expect(found.map { "\($0.label)@\($0.product)@\($0.version)" } == ["Docker php@php@8.4"])
    }
}

@Suite struct ComposerLockTests {
    @Test func readsPackagesAndDevPackagesWithoutV() {
        let lock = """
        {"packages":[{"name":"guzzlehttp/psr7","version":"2.6.1"},{"name":"symfony/console","version":"v7.2.1"},
                     {"name":"acme/x","version":"dev-main"}],
         "packages-dev":[{"name":"phpunit/phpunit","version":"11.5.0"}]}
        """
        #expect(DependencyDetector.isRelevant("composer.lock"))
        let found = DependencyDetector.detect(path: "composer.lock", content: lock)
        #expect(found.map { "\($0.name)@\($0.version)" } == ["guzzlehttp/psr7@2.6.1", "symfony/console@7.2.1", "phpunit/phpunit@11.5.0"])
        #expect(found.allSatisfy { $0.ecosystem == "Packagist" })
    }
}

@Suite struct RustAndDockerArgTests {
    @Test func readsRustToolchainAndCargoMinimum() {
        #expect(StackDetector.isRelevant("rust-toolchain.toml"))
        #expect(StackDetector.isRelevant("Cargo.toml"))
        #expect(!StackDetector.isRelevant("crates/a/Cargo.toml"))
        #expect(StackDetector.detect(path: "rust-toolchain.toml", content: "[toolchain]\nchannel = \"1.99.1\"\n").first?.version == "1.99.1")
        #expect(StackDetector.detect(path: "rust-toolchain.toml", content: "[toolchain]\nchannel = \"stable\"\n").isEmpty)
        #expect(StackDetector.detect(path: "rust-toolchain", content: "1.98.0\n").first?.version == "1.98.0")
        let cargo = StackDetector.detect(path: "Cargo.toml", content: "[workspace.package]\nedition = \"2024\"\nrust-version = \"1.98\"\n")
        #expect(cargo.map { "\($0.product)@\($0.version)" } == ["rust@1.98"])
    }

    @Test func dockerDigestAndArgDefaults() {
        let dockerfile = """
        ARG RUST_VERSION=1.99.1
        ARG UNSET
        FROM rust:${RUST_VERSION}-slim-trixie@sha256:00544ccc AS builder
        FROM postgres:18.6@sha256:74935e72
        FROM node:$UNSET
        FROM gcr.io/distroless/cc-debian13:nonroot@sha256:83b9
        """
        let found = StackDetector.detect(path: "docker/Dockerfile", content: dockerfile)
        #expect(found.map { "\($0.label)@\($0.version)" } == ["Docker rust@1.99.1", "Docker postgres@18.6"])
    }
}

@Suite struct CargoLockTests {
    @Test func readsRegistryPackagesOnly() {
        let lock = """
        version = 4

        [[package]]
        name = "rust-service"
        version = "0.1.0"
        dependencies = [
         "serde",
        ]

        [[package]]
        name = "serde"
        version = "1.0.219"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        checksum = "abc"

        [[package]]
        name = "forked"
        version = "0.2.0"
        source = "git+https://github.com/x/forked#abc"
        """
        #expect(DependencyDetector.isRelevant("fuzz/Cargo.lock"))
        let found = DependencyDetector.detect(path: "Cargo.lock", content: lock)
        #expect(found.map { "\($0.ecosystem):\($0.name)@\($0.version)" } == ["crates.io:serde@1.0.219"])
    }
}
