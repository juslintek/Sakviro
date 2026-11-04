import Foundation

@MainActor
enum ProjectContextHarness {
    static func run(providerName: String) {
        Task { @MainActor in
            do {
                let provider: CopilotProviderKind
                switch providerName {
                case "codex": provider = .codex
                case "copilot": provider = .copilot
                default: throw AnalysisError.badResponse("Use codex or copilot.")
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("Tiltas.txt")
                let document = "Projektas Tiltas. Sutartas biudžetas 5000 eurų. Terminas lapkričio 20 d. Darbai prasideda tik gavus prieigos patvirtinimą."
                try document.write(to: file, atomically: true, encoding: .utf8)
                let kb = KnowledgeBaseService(persistent: false)
                await kb.addDocuments(at: [file])
                try FileManager.default.removeItem(at: directory)
                guard kb.lastError == nil, kb.documents.count == 1 else {
                    throw AnalysisError.badResponse("Fixture indexing failed: \(kb.lastError ?? "no document")")
                }
                let brief = "Projektas Tiltas"
                let question = "Kiek kainuos, iki kada turime baigti ir kokia sąlyga prieš pradedant?"
                let query = CallAnalysisEngine.knowledgeQuery(brief: brief, recent: [question])
                let references = await kb.search(query: query)
                guard references.contains(where: { $0.documentName == "Tiltas.txt" && $0.text.contains("5000") && $0.text.contains("lapkričio 20") }) else {
                    throw AnalysisError.badResponse("Lithuanian project document was not retrieved.")
                }
                let profile = ProfilePresets.makeDefault(persona: "Help the user respond during a project meeting.", tone: "", allowGeneralKnowledge: false)
                let request = AnalysisRequest(transcript: "Them: \(question)", knownInsightTitles: [], references: references,
                    instructions: "Atsakyk lietuviškai, vienu sakiniu, kurį galima pasakyti dabar.", callBrief: brief,
                    allowGeneralKnowledge: false, knownDocumentNames: kb.documentsInPlay(for: nil), persona: profile.persona,
                    counterpart: profile.counterpart, kinds: profile.kinds, gauges: profile.gauges)
                let result = try await CLIAnalysisProvider({ provider }).analyze(request)
                for insight in result.insights {
                    print("kind=\(insight.kindKey) source=\(insight.source ?? "none") reply=\(insight.reply ?? "none")")
                }
                guard result.insights.contains(where: { insight in
                    guard insight.source?.lowercased() == "tiltas.txt", let reply = insight.reply?.lowercased() else { return false }
                    let compact = reply.replacingOccurrences(of: " ", with: "")
                    let remaining = compact.replacingOccurrences(of: "5000", with: "").replacingOccurrences(of: "20", with: "")
                    return compact.contains("5000") && compact.contains("20") && reply.contains("lapkrič")
                        && reply.contains("prieig") && reply.contains("patvirtin") && !remaining.contains(where: \.isNumber)
                }) else { throw AnalysisError.badResponse("No sourced Lithuanian reply with the fixture's budget, deadline and access condition.") }
                print("project-context: PASS (\(providerName), retrieved Tiltas.txt)")
                exit(0)
            } catch {
                print("project-context: FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
