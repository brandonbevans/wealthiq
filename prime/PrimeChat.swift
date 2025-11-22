//
//  PrimeChat.swift
//  prime
//
//  Copied from ElevenLabs ConversationalAISwift example:
//  https://github.com/elevenlabs/elevenlabs-examples/tree/main/examples/conversational-ai/swift/ConversationalAISwift
//

import SwiftUI
import ElevenLabs
import Combine
import LiveKit
import AVFoundation
import AVFAudio

// MARK: - Connection State

enum ConnectionState {
  case idle
  case connecting
  case active
  case reconnecting
  case disconnected
}

// MARK: - Orb UI with Agent State Animation

struct AnimatedOrbView: View {
  let agentState: ElevenLabs.AgentState
  var size: CGFloat = 160 // Default size
  @State private var pulseAmount: CGFloat = 1.0
  @State private var rotation: Double = 0
  
  var body: some View {
    ZStack {
      // Soft outer glow
      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color(red: 0.7, green: 0.8, blue: 1.0).opacity(0.3),
              Color.clear
            ],
            center: .center,
            startRadius: size * 0.4,
            endRadius: size * 1.2
          )
        )
        .frame(width: size * 2, height: size * 2)
        .scaleEffect(pulseAmount * 1.1)

      // Main Sphere (Pearl/Bubble look)
      Circle()
        .fill(
          LinearGradient(
            colors: [
              Color(red: 0.95, green: 0.96, blue: 1.0), // Top-left highlight (White-ish)
              Color(red: 0.85, green: 0.88, blue: 1.0), // Mid (Soft Blue)
              Color(red: 0.75, green: 0.70, blue: 1.0)  // Bottom-right (Soft Purple)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: size, height: size)
        .shadow(
          color: Color(red: 0.6, green: 0.6, blue: 0.9).opacity(0.25),
          radius: size * 0.15,
          x: 0,
          y: size * 0.1
        )
        .scaleEffect(pulseAmount)
      
      // Inner "Bubble" Highlight
      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color.white.opacity(0.8),
              Color.white.opacity(0.0)
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: size * 0.6
          )
        )
        .frame(width: size, height: size)
        .scaleEffect(pulseAmount)
        .offset(x: -size * 0.15, y: -size * 0.15)
      
      // Shimmer/Rotation (Subtle)
      Circle()
        .fill(
          AngularGradient(
            colors: [
              .white.opacity(0.3),
              .clear,
              .white.opacity(0.1),
              .clear
            ],
            center: .center
          )
        )
        .frame(width: size * 0.9, height: size * 0.9)
        .rotationEffect(.degrees(rotation))
        .blur(radius: size * 0.05)
    }
    .onAppear {
      startAnimation()
    }
    .onChange(of: agentState) { _, _ in
      startAnimation()
    }
  }
  
  private var animationSpeed: Double {
    switch agentState {
    case .listening:
      return 2.0
    case .speaking:
      return 0.8
    case .thinking:
      return 1.5
    default:
      return 2.0
    }
  }
  
  private var pulseRange: (min: CGFloat, max: CGFloat) {
    switch agentState {
    case .listening:
      return (0.98, 1.02)
    case .speaking:
      return (0.95, 1.1)
    case .thinking:
      return (0.97, 1.03)
    default:
      return (0.98, 1.02)
    }
  }
  
  private func startAnimation() {
    // Pulse animation
    withAnimation(
      .easeInOut(duration: animationSpeed)
      .repeatForever(autoreverses: true)
    ) {
      pulseAmount = pulseRange.max
    }
    
    // Rotation animation for shimmer
    withAnimation(
      .linear(duration: 8)
      .repeatForever(autoreverses: false)
    ) {
      rotation = 360
    }
  }
}

// MARK: - Conversation ViewModel (using latest ElevenLabs Swift SDK)

@MainActor
final class OrbConversationViewModel: ObservableObject {
  @Published var conversation: Conversation?
  @Published var isConnected: Bool = false
  @Published var isSpeaking: Bool = false
  @Published var audioLevel: Float = 0.0
  @Published var connectionState: ConnectionState = .idle
  @Published var errorMessage: String?
  @Published var isInteractive: Bool = false
  @Published var userProfile: SupabaseManager.UserProfile?
  @Published var microphoneDenied: Bool = false
  @Published var isArchivingSession: Bool = false
  @Published var lastArchiveError: String?
  
  private var cancellables = Set<AnyCancellable>()
  private let audioSession = AVAudioSession.sharedInstance()
  private let conversationAudioEngine = ConversationAudioEngine.shared
  private var lastConversationStartDate: Date?
  private var archivedConversationIds = Set<String>()
  
  func loadUserProfile() async {
    do {
      userProfile = try await SupabaseManager.shared.fetchUserProfile()
      print("✅ Loaded user profile: \(userProfile?.firstName ?? "Unknown")")
    } catch {
      print("⚠️ Failed to load user profile: \(error)")
      errorMessage = "Failed to load profile data"
    }
  }
  
  func toggleConversation(agentId: String) async {
    if isConnected {
      await endConversation()
    } else {
      await startConversation(agentId: agentId)
    }
  }
  
  private func startConversation(agentId: String) async {
    connectionState = .connecting
    errorMessage = nil
    lastArchiveError = nil
    isArchivingSession = false
    
    do {
      let hasPermission = await requestMicrophonePermission()
      guard hasPermission else {
        microphoneDenied = true
        connectionState = .idle
        errorMessage = "Microphone access is required to talk to your coach."
        return
      }
      
      try configureAudioSession()
      
      // Prepare dynamic variables to pass to the agent
      var dynamicVariables: [String: String] = [:]
      
      // Add firstname from user profile if available
      if let firstName = userProfile?.firstName {
        dynamicVariables["firstname"] = firstName
        print("📤 Passing dynamic variable to agent: firstname = \(firstName)")
      }
      
      // Add primary goal from user profile if available
      if let primaryGoal = userProfile?.primaryGoal {
        dynamicVariables["primary_goal"] = primaryGoal
        print("📤 Passing dynamic variable to agent: primary_goal = \(primaryGoal)")
      }
      
      // Add coaching style from user profile if available
      if let coachingStyle = userProfile?.coachingStyle {
        dynamicVariables["coaching_style"] = coachingStyle
        print("📤 Passing dynamic variable to agent: coaching_style = \(coachingStyle)")
      }
      
      let config = ConversationConfig(
        conversationOverrides: ConversationOverrides(textOnly: false),
        dynamicVariables: dynamicVariables
      )
      
      let conv = try await ElevenLabs.startConversation(
        agentId: agentId,
        config: config
      )
      
      conversation = conv
      lastConversationStartDate = Date()
      isInteractive = true
      setupObservers(for: conv)
      conversationAudioEngine.startMusic()
      conversationAudioEngine.attach(conversation: conv)
    } catch {
      print("Error starting conversation: \(error)")
      errorMessage = error.localizedDescription
      connectionState = .disconnected
    }
  }
  
  func endConversation() async {
    await conversation?.endConversation()
    conversationAudioEngine.stop()
    conversation = nil
    isConnected = false
    isSpeaking = false
    audioLevel = 0.0
    connectionState = .idle
    isInteractive = false
    cancellables.removeAll()

    Task { [weak self] in
      await self?.archiveMostRecentConversation()
    }
  }
  
  private func setupObservers(for conversation: Conversation) {
    // Connection state → isConnected and connectionState
    conversation.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        switch state {
        case .active:
          self?.isConnected = true
          self?.connectionState = .active
        case .connecting:
          self?.isConnected = false
          self?.connectionState = .connecting
        case .ended, .idle, .error:
          self?.isConnected = false
          self?.connectionState = .idle
          self?.conversationAudioEngine.stop()
        @unknown default:
          break
        }
      }
      .store(in: &cancellables)
    
    // Agent state → speaking / listening + simple audio level
    conversation.$agentState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] agentState in
        guard let self else { return }
        switch agentState {
        case .listening:
          self.isSpeaking = false
          self.audioLevel = 0.1
        case .speaking:
          self.isSpeaking = true
          self.audioLevel = 0.7
        case .thinking:
          self.isSpeaking = true
          self.audioLevel = 0.5
        @unknown default:
          break
        }
      }
      .store(in: &cancellables)
  }
  
  private func requestMicrophonePermission() async -> Bool {
      return await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
  }
  
  private func configureAudioSession() throws {
    let currentCategory = audioSession.category
    let requiredCategory: AVAudioSession.Category = .playAndRecord
    let requiredMode: AVAudioSession.Mode = .voiceChat
    
    if currentCategory != requiredCategory || audioSession.mode != requiredMode {
      try audioSession.setCategory(
        requiredCategory,
        mode: requiredMode,
        options: [.allowBluetoothHFP, .defaultToSpeaker]
      )
    }
    
    if !audioSession.isOtherAudioPlaying {
      try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
    } else {
      try audioSession.setActive(true)
    }
  }

  // MARK: - Session Archiving

  private func archiveMostRecentConversation() async {
    isArchivingSession = true
    lastArchiveError = nil

    defer { isArchivingSession = false }

    do {
      let summaries = try await ElevenLabsAPI.fetchConversationSummaries()
      guard
        let summary = selectConversationSummary(
          from: summaries,
          startedAt: lastConversationStartDate
        )
      else {
        print("⚠️ No matching conversation found to archive")
        return
      }

      let conversationId = summary.id

      guard !archivedConversationIds.contains(conversationId) else {
        print("ℹ️ Conversation \(conversationId) already archived")
        return
      }

      try await archiveConversation(withId: conversationId, agentId: summary.agentId)
      archivedConversationIds.insert(conversationId)
      lastConversationStartDate = nil
    } catch {
      lastArchiveError = error.localizedDescription
      print("⚠️ Failed to archive conversation audio: \(error)")
      print("Error: \(error)")
      print("Error description: \(String(describing: lastArchiveError))")
    }
  }

  private func selectConversationSummary(
    from summaries: [ElevenLabsAPI.ConversationSummary],
    startedAt startDate: Date?
  ) -> ElevenLabsAPI.ConversationSummary? {
    guard !summaries.isEmpty else { return nil }

    let ordered = summaries.sorted { $0.sortDate > $1.sortDate }

    guard let startDate else {
      return ordered.first
    }

    let windowStart = startDate.addingTimeInterval(-300) // 5 minutes before start
    let windowEnd = Date().addingTimeInterval(600) // up to 10 minutes after now

    return ordered.first { summary in
      guard let createdAt = summary.createdAt else { return true }
      return createdAt >= windowStart && createdAt <= windowEnd
    }
  }

  private func archiveConversation(withId conversationId: String, agentId: String?) async throws {
    let userId = try await SupabaseManager.shared.getCurrentUserId()
    var record = try await SupabaseManager.shared.fetchSessionRecord(conversationId: conversationId)
    var sessionId = record?.id ?? UUID()

    if record == nil {
      record = try await SupabaseManager.shared.insertSessionRecord(
        sessionId: sessionId,
        userId: userId,
        conversationId: conversationId,
        agentId: agentId
      )
      sessionId = record?.id ?? sessionId
    }

    let downloadedAudio = try await downloadConversationAudioWithRetry(conversationId: conversationId)

    let fileExtension = Self.preferredFileExtension(agentFormat: nil, mimeType: downloadedAudio.mimeType)
    let mimeType = downloadedAudio.mimeType ?? Self.defaultMimeType(forExtension: fileExtension)

    _ = try await SupabaseManager.shared.uploadSessionAudio(
      data: downloadedAudio.data,
      userId: userId,
      sessionId: sessionId,
      fileExtension: fileExtension,
      mimeType: mimeType
    )

    print("✅ Archived conversation \(conversationId)")
  }

  private func downloadConversationAudioWithRetry(conversationId: String) async throws -> ElevenLabsAPI.DownloadedAudio {
    let attempts = 3
    for attempt in 1...attempts {
      do {
        return try await ElevenLabsAPI.downloadConversationAudio(conversationId: conversationId)
      } catch ElevenLabsAPI.APIError.invalidResponse(statusCode: 404) where attempt < attempts {
        try await Task.sleep(nanoseconds: 3 * 1_000_000_000) // wait 3s
        continue
      }
    }
    return try await ElevenLabsAPI.downloadConversationAudio(conversationId: conversationId)
  }

  private static func preferredFileExtension(
    agentFormat: String?,
    mimeType: String?
  ) -> String {
    if let mimeType,
      let ext = fileExtension(fromMimeType: mimeType)
    {
      return ext
    }

    guard let agentFormat else {
      return "mp3"
    }

    let normalized = agentFormat.lowercased()
    if normalized.contains("wav") || normalized.contains("pcm") {
      return "wav"
    }
    if normalized.contains("webm") {
      return "webm"
    }
    if normalized.contains("ogg") {
      return "ogg"
    }
    if normalized.contains("mp4") || normalized.contains("m4a") {
      return "m4a"
    }
    if normalized.contains("mp3") {
      return "mp3"
    }
    return "mp3"
  }

  private static func fileExtension(fromMimeType mimeType: String) -> String? {
    let baseMime = mimeType.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    switch baseMime {
    case "audio/mpeg":
      return "mp3"
    case "audio/webm":
      return "webm"
    case "audio/ogg":
      return "ogg"
    case "audio/x-wav", "audio/wav", "audio/vnd.wave":
      return "wav"
    case "audio/mp4", "audio/m4a":
      return "m4a"
    default:
      return nil
    }
  }

  private static func defaultMimeType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "webm":
      return "audio/webm"
    case "ogg":
      return "audio/ogg"
    case "wav":
      return "audio/wav"
    case "m4a", "mp4":
      return "audio/mp4"
    default:
      return "audio/mpeg"
    }
  }
}

// MARK: - Error and Warning Views

struct ErrorBanner: View {
  let message: String
  let onDismiss: () -> Void
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.white)
        .font(.system(size: 20))
      
      Text(message)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)
        .lineLimit(2)
      
      Spacer()
      
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.white)
          .padding(8)
      }
    }
    .padding()
    .background(Color.primeButtonDanger.opacity(0.95))
    .cornerRadius(16)
    .shadow(color: Color.primeButtonDanger.opacity(0.3), radius: 8, x: 0, y: 4)
    .padding(.horizontal)
    .padding(.top, 8)
  }
}

struct WarningBanner: View {
  let message: String
  
  var body: some View {
    HStack(spacing: 12) {
      ProgressView()
        .tint(.white)
      
      Text(message)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)
    }
    .padding()
    .background(Color.primeAccent.opacity(0.95))
    .cornerRadius(16)
    .shadow(color: Color.primeAccent.opacity(0.3), radius: 8, x: 0, y: 4)
    .padding(.horizontal)
    .padding(.top, 8)
  }
}

// MARK: - Main View

struct PrimeChat: View {
  @StateObject private var viewModel = OrbConversationViewModel()
  
  // Use the Agent ID from config directly.
  private let agentId = Config.elevenLabsAgentId
  
  var body: some View {
    ZStack(alignment: .top) {
      // Background
      Color.white.ignoresSafeArea()
      
      // Subtle blue glow at bottom
      GeometryReader { proxy in
        Ellipse()
          .fill(
            Color(red: 0.62, green: 0.83, blue: 1.0)
              .opacity(0.25)
          )
          .frame(width: proxy.size.width * 1.5, height: proxy.size.height * 0.5)
          .position(x: proxy.size.width / 2, y: proxy.size.height * 1.1)
          .blur(radius: 60)
      }
      .ignoresSafeArea()
      
      VStack(spacing: 0) {
        // Top Bar
        HStack {
          // Streak Indicator
          HStack(spacing: 4) {
            Image(systemName: "flame.fill")
              .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.0)) // Orange flame
              .font(.system(size: 16))
            Text("1")
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(Color.black.opacity(0.8))
          }
          
          Spacer()
          
          // Talk / Chat Toggle
          HStack(spacing: 0) {
            // Talk (Active)
            HStack(spacing: 6) {
              Text("Talk")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.white)
            .cornerRadius(20)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            
            // Chat (Inactive)
            HStack(spacing: 6) {
              Text("Chat")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.gray)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
          }
          .padding(4)
          .background(Color(red: 0.96, green: 0.96, blue: 0.98)) // Light gray/blue bg
          .cornerRadius(24)
          
          Spacer()
          
          // User Profile
          if let firstName = viewModel.userProfile?.firstName {
            Circle()
              .fill(Color(red: 0.2, green: 0.2, blue: 0.2)) // Dark gray avatar
              .frame(width: 36, height: 36)
              .overlay(
                Text(firstName.prefix(1).uppercased())
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundColor(.white)
              )
          } else {
            Circle()
              .fill(Color.gray.opacity(0.2))
              .frame(width: 36, height: 36)
              .overlay(Image(systemName: "person.fill").foregroundColor(.gray))
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        
        Spacer()
        
        // Center Content
        VStack(spacing: 32) {
          if viewModel.isConnected {
            AnimatedOrbView(
              agentState: viewModel.conversation?.agentState ?? .listening,
              size: 200
            )
          } else {
            // Idle State - Static Orb or similar
             Circle()
              .fill(
                LinearGradient(
                  colors: [
                    Color(red: 0.95, green: 0.96, blue: 1.0),
                    Color(red: 0.85, green: 0.88, blue: 1.0)
                  ],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
              .frame(width: 200, height: 200)
              .shadow(color: Color.blue.opacity(0.1), radius: 20, x: 0, y: 10)
              .overlay(
                Image(systemName: "mic.fill")
                  .font(.system(size: 40))
                  .foregroundColor(.white.opacity(0.8))
              )
              .onTapGesture {
                Task {
                   await viewModel.toggleConversation(agentId: agentId)
                }
              }
          }
          
          VStack(spacing: 8) {
            Text("Hi \(viewModel.userProfile?.firstName ?? "User"), Welcome to Prime.")
              .font(.system(size: 18, weight: .medium))
              .foregroundColor(.black.opacity(0.8))
              .multilineTextAlignment(.center)
            
            Text("I am your personal AI coach that\nhelps you get things done.")
              .font(.system(size: 16, weight: .regular))
              .foregroundColor(.gray)
              .multilineTextAlignment(.center)
              .lineSpacing(4)
          }
        }
        
        Spacer()
        
        // Bottom Bar
        HStack {
            // Left: Spiral / History
            Button(action: {
                // History action
            }) {
                Image(systemName: "tornado") // Closest SF Symbol to a spiral
                    .font(.system(size: 22))
                    .foregroundColor(Color.black.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            
            Spacer()
            
            // Center: Status / Action Pill
            Button(action: {
                Task {
                   await viewModel.toggleConversation(agentId: agentId)
                }
            }) {
                HStack(spacing: 12) {
                    if viewModel.isConnected {
                        // Status Text (e.g. Listening)
                         Image(systemName: "waveform")
                            .font(.system(size: 14))
                        Text(viewModel.isSpeaking ? "Speaking" : "Listening")
                            .font(.system(size: 16, weight: .medium))
                    } else {
                        Text("Tap to Start")
                             .font(.system(size: 16, weight: .medium))
                    }
                }
                .foregroundColor(.black.opacity(0.8))
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.white)
                .cornerRadius(30)
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
            
            Spacer()
            
            // Right: Mic Toggle (Mute/Unmute) or Stop
            Button(action: {
                 Task {
                   if viewModel.isConnected {
                       await viewModel.endConversation()
                   } else {
                       await viewModel.toggleConversation(agentId: agentId)
                   }
                }
            }) {
                Image(systemName: viewModel.isConnected ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color.black.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 20)
      }
      
      // Banners
      VStack {
        if case .reconnecting = viewModel.connectionState {
          WarningBanner(message: "Reconnecting...")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        
        if let errorMessage = viewModel.errorMessage {
          ErrorBanner(message: errorMessage) {
            viewModel.errorMessage = nil
          }
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
    }
    .onAppear {
      Task {
        await viewModel.loadUserProfile()
      }
    }
    .onDisappear {
      Task {
        if viewModel.isConnected {
          await viewModel.endConversation()
        }
      }
    }
  }
}

#Preview {
  PrimeChat()
}
