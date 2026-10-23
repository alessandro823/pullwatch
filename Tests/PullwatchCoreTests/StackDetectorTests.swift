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
        #expect(found.map { "\($0.label)@\($0.version)" } == ["Docker node@20", "Docker dotnet@8.0"])
        #expect(found.map(\.product) == ["nodejs", "dotnet"])
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
