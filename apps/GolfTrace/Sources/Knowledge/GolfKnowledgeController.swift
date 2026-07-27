import Combine
import Foundation
import NaturalLanguage

@MainActor
final class GolfKnowledgeController: ObservableObject {
  @Published private(set) var profiles: [AIGolfProKnowledgeProfile] = []
  @Published private(set) var selectedProfileID: UUID? = nil
  @Published private(set) var sources: [YouTubeKnowledgeSource] = []
  @Published private(set) var statusText = "สร้างโปรไฟล์ AI โปรก่อนเพิ่มแหล่ง YouTube"
  @Published var mcpEndpoint: String {
    didSet { defaults.set(mcpEndpoint, forKey: Keys.endpoint) }
  }
  @Published var transcriptLanguage: String {
    didSet { defaults.set(transcriptLanguage, forKey: Keys.language) }
  }

  private let defaults: UserDefaults
  private let aiSettings: GolfAISettings
  private let youtubeClient: YouTubeFrameMCPClient
  private let indexer: DSV4KnowledgeIndexer
  private let poseAnalyzer: ReferenceFramePoseAnalyzer
  private let vlmClient: any VisualClaimAnalyzing
  private let storeURL: URL
  private let framesRootURL: URL
  private var tasks: [UUID: Task<Void, Never>] = [:]

  init(
    aiSettings: GolfAISettings,
    defaults: UserDefaults = .standard,
    youtubeClient: YouTubeFrameMCPClient = YouTubeFrameMCPClient(),
    indexer: DSV4KnowledgeIndexer = DSV4KnowledgeIndexer(),
    poseAnalyzer: ReferenceFramePoseAnalyzer = ReferenceFramePoseAnalyzer(),
    vlmClient: any VisualClaimAnalyzing = GX10VLMClient(),
    storeURL: URL? = nil,
    framesRootURL: URL? = nil
  ) {
    self.aiSettings = aiSettings
    self.defaults = defaults
    self.youtubeClient = youtubeClient
    self.indexer = indexer
    self.poseAnalyzer = poseAnalyzer
    self.vlmClient = vlmClient
    let storedEndpoint = defaults.string(forKey: Keys.endpoint)
    if storedEndpoint == Self.legacyTranscriptOnlyEndpoint {
      let migratedEndpoint = YouTubeFrameMCPClient.defaultEndpoint
      mcpEndpoint = migratedEndpoint
      defaults.set(migratedEndpoint, forKey: Keys.endpoint)
    } else {
      mcpEndpoint = storedEndpoint ?? YouTubeFrameMCPClient.defaultEndpoint
    }
    transcriptLanguage = defaults.string(forKey: Keys.language) ?? "en"
    let resolvedStoreURL = storeURL ?? Self.defaultStoreURL()
    self.storeURL = resolvedStoreURL
    self.framesRootURL =
      framesRootURL
      ?? resolvedStoreURL.deletingLastPathComponent()
      .appendingPathComponent("youtube-frames", isDirectory: true)
    load()
  }

  deinit {
    for task in tasks.values {
      task.cancel()
    }
  }

  var selectedProfile: AIGolfProKnowledgeProfile? {
    guard let selectedProfileID else { return nil }
    return profiles.first(where: { $0.id == selectedProfileID })
  }

  var selectedSources: [YouTubeKnowledgeSource] {
    guard let profile = selectedProfile else { return [] }
    let sourceByID = Dictionary(grouping: sources, by: \.id).compactMapValues(\.first)
    return profile.sourceIDs.compactMap { sourceByID[$0] }
  }

  var readyCount: Int { selectedSources.filter { $0.status == .ready }.count }
  var busyCount: Int { selectedSources.filter { $0.status.isBusy }.count }

  @discardableResult
  func createProfile(name: String, teachingStyle: String) -> UUID? {
    let cleanName = String(
      name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
    )
    let cleanStyle = String(
      teachingStyle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
    )
    guard !cleanName.isEmpty else {
      statusText = "กรุณาตั้งชื่อโปรไฟล์ AI โปรก่อนบันทึก"
      return nil
    }
    guard
      !profiles.contains(where: {
        $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
      })
    else {
      statusText = "มีโปรไฟล์ชื่อนี้แล้ว กรุณาเลือกโปรไฟล์เดิมหรือใช้ชื่อใหม่"
      return nil
    }

    let now = Date()
    let profile = AIGolfProKnowledgeProfile(
      id: UUID(),
      name: cleanName,
      teachingStyle: cleanStyle,
      sourceIDs: [],
      createdAt: now,
      updatedAt: now,
      isLegacyImport: false
    )
    profiles.append(profile)
    selectProfile(profile.id)
    statusText = "บันทึกโปรไฟล์ \(profile.name) แล้ว · เพิ่มลิงก์ YouTube ได้"
    save()
    return profile.id
  }

  func updateProfile(_ profileID: UUID, name: String, teachingStyle: String) {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
    let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    guard !cleanName.isEmpty else {
      statusText = "ชื่อโปรไฟล์ว่างไม่ได้"
      return
    }
    let isDuplicate = profiles.contains {
      $0.id != profileID && $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
    }
    guard !isDuplicate else {
      statusText = "มีโปรไฟล์ชื่อนี้แล้ว"
      return
    }
    profiles[index].name = cleanName
    profiles[index].teachingStyle = String(
      teachingStyle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
    )
    profiles[index].updatedAt = Date()
    save()
    statusText = "บันทึกข้อมูลโปรไฟล์แล้ว"
  }

  func selectProfile(_ profileID: UUID) {
    guard profiles.contains(where: { $0.id == profileID }) else { return }
    selectedProfileID = profileID
    defaults.set(profileID.uuidString, forKey: Keys.selectedProfileID)
    let profile = profiles.first(where: { $0.id == profileID })
    statusText =
      "เลือก \(profile?.name ?? "AI โปร") · "
      + "พร้อม \(readyCount) จาก \(selectedSources.count) แหล่ง"
  }

  func removeProfile(_ profileID: UUID) {
    guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
    let candidateOrphans = Set(profile.sourceIDs)
    profiles.removeAll { $0.id == profileID }
    let stillReferenced = Set(profiles.flatMap(\.sourceIDs))
    for sourceID in candidateOrphans.subtracting(stillReferenced) {
      removeSourceAndFiles(sourceID)
    }

    if selectedProfileID == profileID {
      selectedProfileID = profiles.first?.id
      if let selectedProfileID {
        defaults.set(selectedProfileID.uuidString, forKey: Keys.selectedProfileID)
      } else {
        defaults.removeObject(forKey: Keys.selectedProfileID)
      }
    }
    save()
    if profiles.isEmpty {
      statusText = "ลบโปรไฟล์แล้ว · สร้างโปรไฟล์ AI โปรก่อนเพิ่ม YouTube"
    } else {
      statusText = "ลบโปรไฟล์ \(profile.name) แล้ว"
    }
  }

  /// ต้องระบุโปรไฟล์ที่บันทึกแล้วก่อนเสมอ แหล่งเดิมจะถูกแชร์โดยไม่อ่านซ้ำ
  func addURLs(from text: String, to profileID: UUID, processImmediately: Bool = true) {
    guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }) else {
      statusText = "กรุณาสร้างและบันทึกโปรไฟล์ AI โปรก่อนเพิ่ม YouTube"
      return
    }
    let tokens = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    let references = tokens.compactMap(YouTubeVideoReference.parse)
    guard !references.isEmpty else {
      statusText = "ไม่พบลิงก์ YouTube ที่ถูกต้อง"
      return
    }

    var linkedIDs: [UUID] = []
    var newSourceIDs: [UUID] = []
    for reference in references {
      if let existing = sources.first(where: { $0.videoID == reference.videoID }) {
        guard !profiles[profileIndex].sourceIDs.contains(existing.id) else { continue }
        profiles[profileIndex].sourceIDs.append(existing.id)
        linkedIDs.append(existing.id)
        continue
      }
      let source = YouTubeKnowledgeSource(
        id: UUID(),
        videoID: reference.videoID,
        canonicalURL: reference.canonicalURL.absoluteString,
        title: "YouTube · \(reference.videoID)",
        language: transcriptLanguage,
        providerName: "ยังไม่เชื่อมต่อ",
        status: .queued,
        importedAt: nil,
        transcriptHash: nil,
        characterCount: 0,
        chunks: [],
        claims: []
      )
      sources.append(source)
      profiles[profileIndex].sourceIDs.append(source.id)
      linkedIDs.append(source.id)
      newSourceIDs.append(source.id)
    }
    profiles[profileIndex].updatedAt = Date()
    save()
    if linkedIDs.isEmpty {
      statusText = "ลิงก์เหล่านี้อยู่ในโปรไฟล์แล้ว"
    } else {
      statusText = "เพิ่มให้ \(profiles[profileIndex].name) แล้ว \(linkedIDs.count) แหล่ง"
    }
    if processImmediately {
      newSourceIDs.forEach(fetchAndIndex)
    }
  }

  /// API เดิมคงไว้เพื่อให้จุดเรียกเก่าไม่พัง แต่จะไม่ยอมสร้างแหล่งลอยนอกโปรไฟล์
  func addURLs(from text: String) {
    guard let selectedProfileID else {
      statusText = "กรุณาสร้างและบันทึกโปรไฟล์ AI โปรก่อนเพิ่ม YouTube"
      return
    }
    addURLs(from: text, to: selectedProfileID)
  }

  func retry(_ sourceID: UUID) {
    tasks[sourceID]?.cancel()
    fetchAndIndex(sourceID)
  }

  func remove(_ sourceID: UUID) {
    for profileIndex in profiles.indices {
      profiles[profileIndex].sourceIDs.removeAll { $0 == sourceID }
    }
    removeSourceAndFiles(sourceID)
    save()
    statusText = sources.isEmpty ? "ยังไม่มีแหล่ง YouTube" : "ลบแหล่งออกจากทุกโปรไฟล์แล้ว"
  }

  func remove(_ sourceID: UUID, from profileID: UUID) {
    guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
      profiles[profileIndex].sourceIDs.contains(sourceID)
    else { return }
    profiles[profileIndex].sourceIDs.removeAll { $0 == sourceID }
    profiles[profileIndex].updatedAt = Date()

    let isStillUsed = profiles.contains { $0.sourceIDs.contains(sourceID) }
    if !isStillUsed {
      removeSourceAndFiles(sourceID)
    }
    save()
    statusText = "นำแหล่งออกจาก \(profiles[profileIndex].name) แล้ว"
  }

  func verifyMCP() {
    statusText = "กำลังตรวจเครื่องมือ MCP"
    Task { [weak self] in
      guard let self else { return }
      do {
        let tools = try await youtubeClient.verify(endpoint: mcpEndpoint)
        let requiredTools = ["get_transcript", "get_video_frame"]
        let missingTools = requiredTools.filter { !tools.contains($0) }
        guard missingTools.isEmpty else {
          statusText = "เชื่อมต่อได้ แต่ยังขาด tool: \(missingTools.joined(separator: ", "))"
          return
        }
        statusText = "MCP พร้อมอ่านทั้งคำพูดและภาพ · \(tools.count) tools"
      } catch {
        statusText = error.localizedDescription
      }
    }
  }

  func reindexReadyTranscripts() {
    for source in selectedSources where !source.chunks.isEmpty && source.status != .indexing {
      indexOnly(source.id)
    }
  }

  func refreshVisualEvidence(_ sourceID: UUID) {
    guard let source = sources.first(where: { $0.id == sourceID }), !source.status.isBusy else {
      statusText = "รออ่านคำพูดให้เสร็จก่อน แล้วจึงอ่านภาพใหม่"
      return
    }
    tasks[sourceID]?.cancel()
    tasks[sourceID] = nil
    fetchVisualEvidence(sourceID)
  }

  func imageURL(for frame: ReferenceFrameObservation) -> URL? {
    let relative = frame.relativeImagePath as NSString
    guard !relative.isAbsolutePath,
      !relative.pathComponents.contains("..")
    else { return nil }
    let candidate = framesRootURL.appendingPathComponent(frame.relativeImagePath)
      .standardizedFileURL
    let rootPath = framesRootURL.standardizedFileURL.path + "/"
    guard candidate.path.hasPrefix(rootPath) else { return nil }
    return candidate
  }

  func excerpts(
    for question: String,
    clubFamily: String,
    cameraView: String,
    limit: Int = 6
  ) -> [GolfKnowledgeExcerpt] {
    guard let activeProfile = selectedProfile else { return [] }
    let queryTerms = Self.terms(in: "\(question) \(clubFamily) \(cameraView)")
    let candidates = selectedSources.flatMap {
      source -> [(score: Int, excerpt: GolfKnowledgeExcerpt)] in
      guard source.status == .ready else { return [] }
      return source.claims.compactMap { claim in
        let textTerms = Self.terms(
          in: ([claim.text] + claim.clubFamilies + claim.cameraViews + claim.topics).joined(
            separator: " ")
        )
        let overlap = queryTerms.intersection(textTerms).count
        let applicability =
          claim.clubFamilies.contains(where: {
            clubFamily.localizedCaseInsensitiveContains($0)
              || $0.localizedCaseInsensitiveContains(clubFamily)
          }) ? 2 : 0
        let visualEvidence = source.frames?.filter {
          $0.linkedClaimIDs.contains(claim.id) && $0.hasUsableVisualEvidence
        }
        let visualGroundings = source.visualGroundings?.filter {
          $0.supportedClaimIDs.contains(claim.id)
            || $0.contradictedClaimIDs.contains(claim.id)
        }
        let score = overlap * 3 + applicability
        guard score > 0 else { return nil }
        return (
          score,
          GolfKnowledgeExcerpt(
            id: claim.id,
            sourceID: source.id,
            sourceTitle: "\(activeProfile.name) · \(source.title)",
            sourceURL: source.canonicalURL,
            startSeconds: claim.startSeconds,
            text: claim.text,
            limitations: claim.limitations,
            profileID: activeProfile.id,
            profileName: activeProfile.name,
            visualEvidence: visualEvidence,
            visualGroundings: visualGroundings
          )
        )
      }
    }

    let sorted = candidates.sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.excerpt.id < $1.excerpt.id
    }
    var selected: [GolfKnowledgeExcerpt] = []
    var usedSources: Set<UUID> = []
    for candidate in sorted where selected.count < limit {
      if selected.count < min(limit, readyCount), usedSources.contains(candidate.excerpt.sourceID) {
        continue
      }
      selected.append(candidate.excerpt)
      usedSources.insert(candidate.excerpt.sourceID)
    }
    if selected.count < limit {
      for candidate in sorted where selected.count < limit && !selected.contains(candidate.excerpt)
      {
        selected.append(candidate.excerpt)
      }
    }
    return selected
  }

  private func fetchAndIndex(_ sourceID: UUID) {
    guard let index = sources.firstIndex(where: { $0.id == sourceID }),
      let reference = YouTubeVideoReference.parse(sources[index].canonicalURL)
    else { return }
    sources[index].status = .fetchingTranscript
    save()

    let endpoint = mcpEndpoint
    let language = sources[index].language
    tasks[sourceID] = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await youtubeClient.fetchTranscript(
          for: reference,
          endpoint: endpoint,
          language: language
        )
        guard !Task.isCancelled,
          let current = sources.firstIndex(where: { $0.id == sourceID })
        else { return }
        sources[current].providerName = result.providerName
        sources[current].status = .transcriptReady
        sources[current].importedAt = Date()
        sources[current].transcriptHash = result.transcriptHash
        sources[current].characterCount = result.characterCount
        sources[current].chunks = result.chunks
        sources[current].claims = []
        save()
        statusText = "พบคำถอดเสียงแล้ว กำลังส่งข้อความให้ DeepSeek-V4-Flash อ่าน"
        tasks[sourceID] = nil
        indexOnly(sourceID)
        return
      } catch is CancellationError {
        return
      } catch YouTubeTranscriptMCPError.noTranscript {
        guard !Task.isCancelled else { return }
        update(sourceID) { $0.status = .noTranscript }
        statusText = YouTubeTranscriptMCPError.noTranscript.localizedDescription
      } catch {
        guard !Task.isCancelled else { return }
        update(sourceID) { $0.status = .failed(error.localizedDescription) }
        statusText = error.localizedDescription
      }
      tasks[sourceID] = nil
    }
  }

  private func indexOnly(_ sourceID: UUID) {
    guard let index = sources.firstIndex(where: { $0.id == sourceID }),
      !sources[index].chunks.isEmpty
    else { return }

    do {
      guard let endpoint = aiSettings.dsv4URL else {
        sources[index].status = .transcriptReady
        statusText = "พบ transcript แล้ว · กำลังดึงภาพก่อน ระหว่างรอตั้งค่า OpenRouter"
        save()
        tasks[sourceID] = nil
        fetchVisualEvidence(sourceID)
        return
      }
      guard let key = try aiSettings.loadAPIKey(), !key.isEmpty else {
        sources[index].status = .transcriptReady
        statusText = "พบ transcript แล้ว · กำลังดึงภาพก่อน ระหว่างรอ OpenRouter key"
        save()
        tasks[sourceID] = nil
        fetchVisualEvidence(sourceID)
        return
      }
      let source = sources[index]
      sources[index].status = .indexing
      save()
      let configuration = DSV4KnowledgeIndexConfiguration(
        endpoint: endpoint,
        model: aiSettings.dsv4Model,
        apiKey: key,
        employeeCode: aiSettings.employeeCode
      )

      tasks[sourceID]?.cancel()
      tasks[sourceID] = Task { [weak self] in
        guard let self else { return }
        do {
          let claims = try await indexer.index(source: source, configuration: configuration)
          guard !Task.isCancelled else { return }
          update(sourceID) {
            $0.claims = claims
            $0.status = claims.isEmpty ? .failed("ไม่พบเนื้อหาการสอนกอล์ฟในคำถอดเสียง") : .ready
          }
          if claims.isEmpty {
            statusText = "ไม่พบแนวคิดจากคำพูด · กำลังเก็บภาพตัวอย่างไว้ตรวจ"
          } else {
            statusText = "พบ \(claims.count) แนวคิด · กำลังดึงภาพรอบเวลาที่โปรอธิบาย"
          }
          tasks[sourceID] = nil
          fetchVisualEvidence(sourceID)
          return
        } catch is CancellationError {
          return
        } catch {
          guard !Task.isCancelled else { return }
          update(sourceID) { $0.status = .failed(error.localizedDescription) }
          statusText = "DeepSeek อ่านไม่สำเร็จ · จะดึงภาพตัวอย่างไว้ก่อน"
          tasks[sourceID] = nil
          fetchVisualEvidence(sourceID)
          return
        }
      }
    } catch {
      sources[index].status = .transcriptReady
      statusText = error.localizedDescription
      save()
    }
  }

  private func fetchVisualEvidence(_ sourceID: UUID) {
    guard let index = sources.firstIndex(where: { $0.id == sourceID }),
      let reference = YouTubeVideoReference.parse(sources[index].canonicalURL)
    else { return }

    let source = sources[index]
    let targets = Self.frameTargets(for: source)
    guard !targets.isEmpty else {
      sources[index].visualStatus = .unavailable
      statusText = "ยังไม่มีช่วงเวลาที่ใช้เลือกภาพอ้างอิงได้"
      save()
      return
    }

    sources[index].visualStatus = .fetching
    save()
    let endpoint = mcpEndpoint

    tasks[sourceID] = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      var observations: [ReferenceFrameObservation] = []
      var vlmFrameInputsByHash: [String: GX10VLMFrameInput] = [:]
      var failureMessages: [String] = []

      for (targetIndex, target) in targets.enumerated() {
        guard !Task.isCancelled else { return }
        do {
          let result = try await youtubeClient.fetchFrame(
            videoURL: reference.canonicalURL,
            timestamp: target.timestampSeconds,
            endpoint: endpoint,
            provider: .youtubeContext,
            maxWidth: 640
          )
          guard !Task.isCancelled else { return }
          let relativePath = try await storeFrame(result, videoID: reference.videoID)
          let observation = try await poseAnalyzer.analyze(
            frameData: result.data,
            mimeType: result.mimeType,
            timestampSeconds: result.timestamp,
            relativeImagePath: relativePath,
            linkedClaimIDs: target.claimIDs,
            sha256: result.sha256
          )
          guard !Task.isCancelled else { return }
          observations.append(observation)
          vlmFrameInputsByHash[result.sha256] = GX10VLMFrameInput(
            data: result.data,
            mimeType: result.mimeType,
            timestampSeconds: result.timestamp,
            sha256: result.sha256
          )
          statusText = "อ่านภาพอ้างอิงแล้ว \(targetIndex + 1) จาก \(targets.count) เฟรม"
        } catch is CancellationError {
          return
        } catch {
          failureMessages.append(error.localizedDescription)
        }
      }

      guard !Task.isCancelled else { return }
      let unique = Dictionary(grouping: observations, by: \.id).compactMap { _, values in
        values.first
      }.sorted { $0.timestampSeconds < $1.timestampSeconds }
      let usableCount = unique.filter(\.hasUsableVisualEvidence).count
      update(sourceID) {
        if unique.isEmpty {
          let message = failureMessages.first ?? "ยังไม่พบภาพอ้างอิงที่อ่านได้"
          $0.visualStatus = .failed(String(message.prefix(240)))
        } else {
          $0.frames = unique
          $0.visualStatus = usableCount > 0 ? .ready : .unavailable
        }
      }

      if unique.isEmpty {
        statusText = failureMessages.first ?? "ดึงภาพจาก MCP ไม่สำเร็จ"
      } else {
        statusText =
          "ภาพพร้อม \(unique.count) เฟรม · ใช้เป็นหลักฐานได้ \(usableCount) เฟรม"
        await analyzeVisualGroundings(
          sourceID,
          frameInputs: Array(vlmFrameInputsByHash.values)
        )
      }
      tasks[sourceID] = nil
    }
  }

  /// ทำขั้น VLM แยกจาก MCP และ Apple Vision เพื่อให้ทดสอบ/ลองใหม่ได้โดยไม่ล้างผลที่ดีอยู่
  /// แต่ละ call มี claim เดียว เฟรมไม่เกิน 3 ภาพ และทำตามลำดับเพื่อไม่แย่งทรัพยากร GX10
  func analyzeVisualGroundings(
    _ sourceID: UUID,
    frameInputs: [GX10VLMFrameInput]
  ) async {
    guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }

    guard aiSettings.vlmEnabled else {
      update(sourceID) { $0.visualGroundingStatus = .notRequested }
      return
    }

    let model = aiSettings.vlmModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let endpoint = aiSettings.vlmURL, !model.isEmpty, model.count <= 200 else {
      let message = "เปิด GX10 VLM แล้ว แต่ endpoint หรือ model ยังไม่ถูกต้อง"
      update(sourceID) { $0.visualGroundingStatus = .failed(message) }
      statusText = message
      return
    }

    let source = sources[index]
    let targets = Self.visualGroundingTargets(source: source, frameInputs: frameInputs)
    guard !targets.isEmpty else {
      update(sourceID) { $0.visualGroundingStatus = .notRequested }
      statusText = "ภาพพร้อมแล้ว แต่ยังไม่มี claim ที่ผูกกับเฟรมสำหรับ GX10 VLM"
      return
    }

    update(sourceID) { $0.visualGroundingStatus = .analyzing }
    statusText = "GX10 VLM กำลังตรวจ claim กับภาพ 0 จาก \(targets.count) ข้อ"

    var groundings = source.visualGroundings ?? []
    var failureMessages: [String] = []
    var successCount = 0

    for (targetIndex, target) in targets.enumerated() {
      guard !Task.isCancelled else {
        update(sourceID) {
          $0.visualGroundingStatus = groundings.isEmpty ? .notRequested : .ready
        }
        return
      }
      do {
        let grounding = try await vlmClient.analyze(
          frames: target.frames,
          transcript: target.transcript,
          claims: [target.claim],
          endpoint: endpoint,
          model: model
        )
        guard
          grounding.supportedClaimIDs.contains(target.claim.id)
            || grounding.contradictedClaimIDs.contains(target.claim.id)
        else {
          failureMessages.append("VLM ไม่ได้ผูกผลกลับมายัง claim ที่ส่งให้ตรวจ")
          continue
        }

        groundings.removeAll {
          $0.supportedClaimIDs.contains(target.claim.id)
            || $0.contradictedClaimIDs.contains(target.claim.id)
        }
        groundings.append(grounding)
        successCount += 1
        statusText =
          "GX10 VLM ตรวจ claim แล้ว \(targetIndex + 1) จาก \(targets.count) ข้อ"
      } catch is CancellationError {
        update(sourceID) {
          $0.visualGroundingStatus = groundings.isEmpty ? .notRequested : .ready
        }
        return
      } catch {
        failureMessages.append(error.localizedDescription)
      }
    }

    let uniqueGroundings = Dictionary(grouping: groundings, by: \.id).compactMap { _, values in
      values.last
    }.sorted { $0.id < $1.id }
    let failureMessage = failureMessages.first.map {
      "GX10 VLM ตรวจภาพไม่ครบ: \(String($0.prefix(200)))"
    }
    update(sourceID) {
      $0.visualGroundings = uniqueGroundings
      $0.visualGroundingStatus = failureMessage.map(YouTubeVisualGroundingStatus.failed) ?? .ready
    }

    if let failureMessage {
      statusText =
        "ภาพและ Apple Vision ยังพร้อม · \(failureMessage) · เก็บผล VLM ล่าสุดไว้แล้ว"
    } else {
      statusText = "GX10 VLM ผูกภาพกับ claim แล้ว \(successCount) ข้อ"
    }
  }

  private func storeFrame(
    _ frame: YouTubeFrameMCPResult,
    videoID: String
  ) async throws -> String {
    let extensionName = frame.mimeType == "image/png" ? "png" : "jpg"
    let relativePath = "\(videoID)/\(frame.sha256).\(extensionName)"
    guard let directory = safeFrameDirectory(videoID: videoID) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let destination = directory.appendingPathComponent("\(frame.sha256).\(extensionName)")
    let frameData = frame.data
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: destination.path) {
        try frameData.write(to: destination, options: .atomic)
      }
    }.value
    return relativePath
  }

  private struct FrameTarget {
    let timestampSeconds: Double
    let claimIDs: [String]
  }

  private struct VisualGroundingTarget {
    let claim: GolfTeachingClaim
    let transcript: String
    let frames: [GX10VLMFrameInput]
  }

  private static func visualGroundingTargets(
    source: YouTubeKnowledgeSource,
    frameInputs: [GX10VLMFrameInput]
  ) -> [VisualGroundingTarget] {
    let inputByHash = Dictionary(grouping: frameInputs, by: \.sha256).compactMapValues(\.first)
    let chunksByID = Dictionary(uniqueKeysWithValues: source.chunks.map { ($0.id, $0) })
    let observations = (source.frames ?? []).sorted { $0.timestampSeconds < $1.timestampSeconds }

    return source.claims.compactMap { claim -> VisualGroundingTarget? in
      guard let chunk = chunksByID[claim.sourceChunkID] else { return nil }
      var seenHashes: Set<String> = []
      let linkedFrames = observations.compactMap { observation -> GX10VLMFrameInput? in
        guard observation.linkedClaimIDs.contains(claim.id),
          seenHashes.insert(observation.sha256).inserted
        else { return nil }
        return inputByHash[observation.sha256]
      }
      guard !linkedFrames.isEmpty else { return nil }
      return VisualGroundingTarget(
        claim: claim,
        transcript: chunk.text,
        frames: Array(linkedFrames.prefix(3))
      )
    }.prefix(6).map { $0 }
  }

  private static func frameTargets(for source: YouTubeKnowledgeSource) -> [FrameTarget] {
    let claimsByChunk = Dictionary(grouping: source.claims, by: \.sourceChunkID)
    let claimedChunks = source.chunks.filter { claimsByChunk[$0.id]?.isEmpty == false }
    let candidateChunks =
      claimedChunks.isEmpty
      ? source.chunks.filter { $0.startSeconds != nil }
      : claimedChunks
    let selectedChunks = evenlySelected(candidateChunks, limit: 6)
    var targetsByMillisecond: [Int: FrameTarget] = [:]

    for chunk in selectedChunks {
      let claimIDs = claimsByChunk[chunk.id, default: []].map(\.id).sorted()
      guard let start = chunk.startSeconds else { continue }
      let end = max(start, chunk.endSeconds ?? start)
      let timestamps: [Double]
      if end - start >= 2 {
        timestamps = [start + 0.5, (start + end) / 2, max(start + 0.5, end - 0.5)]
      } else {
        timestamps = [max(0, start - 2), start, start + 2]
      }

      for timestamp in timestamps {
        let rounded = max(0, (timestamp * 2).rounded() / 2)
        let key = Int((rounded * 1_000).rounded())
        if let existing = targetsByMillisecond[key] {
          targetsByMillisecond[key] = FrameTarget(
            timestampSeconds: existing.timestampSeconds,
            claimIDs: Array(Set(existing.claimIDs + claimIDs)).sorted()
          )
        } else {
          targetsByMillisecond[key] = FrameTarget(
            timestampSeconds: rounded,
            claimIDs: claimIDs
          )
        }
      }
    }

    return targetsByMillisecond.values.sorted { $0.timestampSeconds < $1.timestampSeconds }
  }

  private static func evenlySelected<T>(_ values: [T], limit: Int) -> [T] {
    guard limit > 0, values.count > limit else { return values }
    if limit == 1 { return [values[values.count / 2]] }
    let step = Double(values.count - 1) / Double(limit - 1)
    return (0..<limit).map { values[Int((Double($0) * step).rounded())] }
  }

  private func update(_ sourceID: UUID, mutation: (inout YouTubeKnowledgeSource) -> Void) {
    guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
    mutation(&sources[index])
    save()
  }

  private func removeSourceAndFiles(_ sourceID: UUID) {
    tasks[sourceID]?.cancel()
    tasks[sourceID] = nil
    if let source = sources.first(where: { $0.id == sourceID }),
      let directory = safeFrameDirectory(for: source),
      FileManager.default.fileExists(atPath: directory.path)
    {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        statusText = "นำแหล่งออกแล้ว แต่ลบภาพอ้างอิงไม่สำเร็จ: \(error.localizedDescription)"
      }
    }
    sources.removeAll { $0.id == sourceID }
  }

  private func load() {
    guard let data = try? Data(contentsOf: storeURL) else { return }

    let decoder = JSONDecoder()
    var migratedLegacyStore = false
    if let library = try? decoder.decode(StoredKnowledgeLibrary.self, from: data) {
      profiles = library.profiles
      sources = library.sources
    } else if let legacySources = try? decoder.decode([YouTubeKnowledgeSource].self, from: data) {
      sources = legacySources
      migratedLegacyStore = true
      backupLegacyStore(data)
    } else {
      statusText = "อ่านคลังความรู้เดิมไม่ได้ · ยังไม่ได้แก้หรือลบไฟล์เดิม"
      return
    }

    sources = sources.map { source in
      var copy = source
      if copy.status.isBusy {
        copy.status = copy.chunks.isEmpty ? .queued : .transcriptReady
      }
      if copy.visualStatus?.isBusy == true {
        copy.visualStatus = copy.frames?.isEmpty == false ? .ready : .notRequested
      }
      if copy.visualGroundingStatus?.isBusy == true {
        copy.visualGroundingStatus =
          copy.visualGroundings?.isEmpty == false ? .ready : .notRequested
      }
      return copy
    }

    let validSourceIDs = Set(sources.map(\.id))
    profiles = profiles.map { profile in
      var copy = profile
      var seen: Set<UUID> = []
      copy.sourceIDs = copy.sourceIDs.filter {
        validSourceIDs.contains($0) && seen.insert($0).inserted
      }
      return copy
    }

    let referencedSourceIDs = Set(profiles.flatMap(\.sourceIDs))
    let orphanSourceIDs = sources.map(\.id).filter { !referencedSourceIDs.contains($0) }
    if !orphanSourceIDs.isEmpty {
      if let legacyIndex = profiles.firstIndex(where: \.isLegacyImport) {
        profiles[legacyIndex].sourceIDs.append(contentsOf: orphanSourceIDs)
        profiles[legacyIndex].updatedAt = Date()
      } else {
        let now = Date()
        profiles.append(
          AIGolfProKnowledgeProfile(
            id: UUID(),
            name: "โปรไฟล์จากข้อมูลเดิม",
            teachingStyle: "แหล่งอ้างอิงที่เคยเพิ่มไว้ก่อนระบบโปรไฟล์",
            sourceIDs: orphanSourceIDs,
            createdAt: now,
            updatedAt: now,
            isLegacyImport: true
          )
        )
      }
      migratedLegacyStore = true
    }

    if let rawSelectedID = defaults.string(forKey: Keys.selectedProfileID),
      let storedSelectedID = UUID(uuidString: rawSelectedID),
      profiles.contains(where: { $0.id == storedSelectedID })
    {
      selectedProfileID = storedSelectedID
    } else {
      selectedProfileID = profiles.first?.id
      if let selectedProfileID {
        defaults.set(selectedProfileID.uuidString, forKey: Keys.selectedProfileID)
      }
    }

    if migratedLegacyStore {
      save()
      statusText = "ย้ายแหล่ง YouTube เดิมเข้าโปรไฟล์ให้แล้ว · ข้อมูลเดิมยังอยู่ครบ"
    } else if let selectedProfile {
      statusText =
        "เลือก \(selectedProfile.name) · "
        + "พร้อม \(readyCount) จาก \(selectedSources.count) แหล่ง"
    }
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: storeURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let library = StoredKnowledgeLibrary(
        schemaVersion: 2,
        profiles: profiles,
        sources: sources
      )
      try encoder.encode(library).write(to: storeURL, options: .atomic)
    } catch {
      statusText = "บันทึกคลังความรู้ไม่สำเร็จ: \(error.localizedDescription)"
    }
  }

  /// เก็บสำเนารูปแบบ array รุ่นเดิมไว้หนึ่งชุดก่อนเขียน library รุ่นใหม่
  /// เพื่อให้กู้/ย้อนรุ่นได้โดยไม่ต้องแปลงข้อมูลกลับด้วยมือ
  private func backupLegacyStore(_ data: Data) {
    let backupURL = storeURL.deletingPathExtension()
      .appendingPathExtension("legacy-v1.json")
    guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
    do {
      try data.write(to: backupURL, options: .atomic)
    } catch {
      statusText = "ย้ายข้อมูลได้ แต่สำรองไฟล์รูปแบบเดิมไม่สำเร็จ: \(error.localizedDescription)"
    }
  }

  private static func defaultStoreURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("GolfTrace", isDirectory: true)
      .appendingPathComponent("youtube-knowledge.json")
  }

  private static func terms(in value: String) -> Set<String> {
    let normalized = value.lowercased()
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = normalized
    var terms: Set<String> = []
    tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
      let term = normalized[range].trimmingCharacters(in: .punctuationCharacters)
      if term.count >= 2 { terms.insert(term) }
      return true
    }
    return terms
  }

  private func safeFrameDirectory(for source: YouTubeKnowledgeSource) -> URL? {
    guard let reference = YouTubeVideoReference.parse(source.canonicalURL) else { return nil }
    return safeFrameDirectory(videoID: reference.videoID)
  }

  private func safeFrameDirectory(videoID: String) -> URL? {
    guard let reference = YouTubeVideoReference.parse(videoID), reference.videoID == videoID else {
      return nil
    }
    let root = framesRootURL.standardizedFileURL.resolvingSymlinksInPath()
    let directory = root.appendingPathComponent(videoID, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard directory.path.hasPrefix(root.path + "/") else { return nil }
    return directory
  }

  private enum Keys {
    static let endpoint = "GolfTrace.Knowledge.mcpEndpoint"
    static let language = "GolfTrace.Knowledge.language"
    static let selectedProfileID = "GolfTrace.Knowledge.selectedProfileID"
  }

  private struct StoredKnowledgeLibrary: Codable {
    let schemaVersion: Int
    var profiles: [AIGolfProKnowledgeProfile]
    var sources: [YouTubeKnowledgeSource]
  }

  /// ค่าเริ่มต้นรุ่นเก่ารองรับ transcript อย่างเดียวและไม่มีเฟรมตามเวลา
  /// ย้ายเฉพาะค่าที่ตรงกันทุกตัวอักษร เพื่อไม่ทับ endpoint ที่ผู้ใช้ตั้งเอง
  private static let legacyTranscriptOnlyEndpoint =
    "https://youtube-transcript-mcp.ergut.workers.dev/mcp"
}
