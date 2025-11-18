//
//  ConversationalAIExampleView.swift
//  wealthiq
//
//  Copied from ElevenLabs ConversationalAISwift example:
//  https://github.com/elevenlabs/elevenlabs-examples/tree/main/examples/conversational-ai/swift/ConversationalAISwift
//

import SwiftUI
import ElevenLabs
import Combine
import LiveKit

// MARK: - Connection State

enum ConnectionState {
  case idle
  case connecting
  case active
  case reconnecting
  case disconnected
}

// MARK: - Orb UI

enum OrbMode {
  case listening
  case speaking
}

struct OrbView: View {
  let mode: OrbMode
  let audioLevel: Float
  
  private var iconName: String {
    switch mode {
    case .listening:
      return "waveform"
    case .speaking:
      return "speaker.wave.2.fill"
    }
  }
  
  private var scale: CGFloat {
    0.9 + CGFloat(audioLevel * 3)
  }
  
  var body: some View {
    ZStack {
      // Orb image with glow effect
      Image("orb")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(height: 200)
        .shadow(color: .purple.opacity(0.3), radius: 20, x: 0, y: 10)
      
      // White circle background with blur effect
      Circle()
        .fill(.white)
        .frame(width: 56, height: 56)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .blur(radius: 0.5)
        .scaleEffect(scale)
        .animation(.spring(response: 0.1, dampingFraction: 0.8), value: scale)
      
      // Mode icon
      Image(systemName: iconName)
        .font(.system(size: 28, weight: .medium))
        .foregroundColor(.black)
        .scaleEffect(scale)
        .animation(.spring(response: 0.1, dampingFraction: 0.8), value: scale)
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
  
  private var cancellables = Set<AnyCancellable>()
  
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
    
    do {
      let config = ConversationConfig(
        conversationOverrides: ConversationOverrides(textOnly: false)
      )
      
      let conv = try await ElevenLabs.startConversation(
        agentId: agentId,
        config: config
      )
      
      conversation = conv
      isInteractive = true
      setupObservers(for: conv)
    } catch {
      print("Error starting conversation: \(error)")
      errorMessage = error.localizedDescription
      connectionState = .disconnected
    }
  }
  
  private func endConversation() async {
    await conversation?.endConversation()
    conversation = nil
    isConnected = false
    isSpeaking = false
    audioLevel = 0.0
    connectionState = .idle
    isInteractive = false
    cancellables.removeAll()
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
        @unknown default:
          self?.isConnected = false
          self?.connectionState = .idle
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
    .background(Color.red.opacity(0.9))
    .cornerRadius(12)
    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
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
    .background(Color.orange.opacity(0.9))
    .cornerRadius(12)
    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    .padding(.horizontal)
    .padding(.top, 8)
  }
}

struct AgentListeningIndicator: View {
  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.green)
        .frame(width: 8, height: 8)
      
      Text("Listening...")
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.gray)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.white.opacity(0.9))
    .cornerRadius(20)
    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
  }
}

// MARK: - Main View

struct ConversationalAIExampleView: View {
  @State private var currentAgentIndex = 0
  @StateObject private var viewModel = OrbConversationViewModel()
  
  let agents = [
    Agent(
      id: "agent_2601ka9xkvjge6vswgmh8av21061",
      name: "Matilda",
      description: "Math tutor"
    ),
    Agent(
      id: "agent_2601ka9xkvjge6vswgmh8av21061",
      name: "Eric",
      description: "Support agent"
    ),
    Agent(
      id: "agent_2601ka9xkvjge6vswgmh8av21061",
      name: "Callum",
      description: "Video game character"
    )
  ]
  
  private func beginConversation(agent: Agent) {
    Task {
      await viewModel.toggleConversation(agentId: agent.id)
    }
  }
  
  var body: some View {
    ZStack(alignment: .top) {
      // Background gradient
      LinearGradient(
        colors: [
          Color(red: 0.95, green: 0.95, blue: 0.98),
          Color(red: 0.98, green: 0.96, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
      
      if viewModel.isInteractive {
        interactionView()
      } else {
        startView()
      }
      
      // Warning banner for reconnecting state
      if case .reconnecting = viewModel.connectionState {
        VStack {
          WarningBanner(message: "Reconnecting...")
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      
      // Error banner
      if let errorMessage = viewModel.errorMessage {
        VStack {
          ErrorBanner(message: errorMessage) {
            viewModel.errorMessage = nil
          }
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isInteractive)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.connectionState)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.errorMessage)
    .navigationTitle("Conversation")
    .navigationBarTitleDisplayMode(.inline)
  }
  
  @ViewBuilder
  private func startView() -> some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        // Logo at top
        VStack {
          Image("logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 40)
            .padding(.top, 16)
          
          Spacer()
        }
        
        // Main content
        VStack(spacing: 24) {
          OrbView(
            mode: .listening,
            audioLevel: 0.05
          )
          .padding(.bottom, 12)
          
          VStack(spacing: 8) {
            Text(agents[currentAgentIndex].name)
              .font(.system(size: 32, weight: .bold))
              .foregroundColor(Color(red: 0.13, green: 0.06, blue: 0.16))
            
            Text(agents[currentAgentIndex].description)
              .font(.system(size: 18, weight: .medium))
              .foregroundColor(.gray)
          }
          
          // Agent indicators
          HStack(spacing: 12) {
            ForEach(0..<agents.count, id: \.self) { index in
              Circle()
                .fill(index == currentAgentIndex ? Color(red: 0.39, green: 0.27, blue: 0.92) : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
                .scaleEffect(index == currentAgentIndex ? 1.2 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: currentAgentIndex)
            }
          }
          .padding(.top, 8)
          
          Spacer()
            .frame(height: 40)
          
          CallButton(
            isConnected: viewModel.isConnected,
            connectionState: viewModel.connectionState,
            action: { beginConversation(agent: agents[currentAgentIndex]) }
          )
          .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity)
        .frame(height: geometry.size.height)
      }
    }
    .gesture(
      DragGesture(minimumDistance: 30)
        .onEnded { value in
          guard !viewModel.isConnected else { return }
          
          withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if value.translation.width < -50 && currentAgentIndex < agents.count - 1 {
              currentAgentIndex += 1
            } else if value.translation.width > 50 && currentAgentIndex > 0 {
              currentAgentIndex -= 1
            }
          }
        }
    )
  }
  
  @ViewBuilder
  private func interactionView() -> some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        // Logo at top
        VStack {
          Image("logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 40)
            .padding(.top, 16)
          
          Spacer()
        }
        
        // Conversation content
        VStack(spacing: 24) {
          Spacer()
          
          OrbView(
            mode: viewModel.isSpeaking ? .speaking : .listening,
            audioLevel: viewModel.audioLevel
          )
          .padding(.bottom, 12)
          
          VStack(spacing: 8) {
            Text(agents[currentAgentIndex].name)
              .font(.system(size: 32, weight: .bold))
              .foregroundColor(Color(red: 0.13, green: 0.06, blue: 0.16))
            
            Text(viewModel.isSpeaking ? "Speaking..." : "Listening...")
              .font(.system(size: 18, weight: .medium))
              .foregroundColor(viewModel.isSpeaking ? Color(red: 0.39, green: 0.27, blue: 0.92) : .gray)
          }
          
          Spacer()
          
          CallButton(
            isConnected: viewModel.isConnected,
            connectionState: viewModel.connectionState,
            action: { beginConversation(agent: agents[currentAgentIndex]) }
          )
          .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity)
        .frame(height: geometry.size.height)
      }
    }
  }
}

// MARK: - Call Button Component
struct CallButton: View {
  let isConnected: Bool
  let connectionState: ConnectionState
  let action: () -> Void
  
  private var buttonIcon: String {
    switch connectionState {
    case .connecting:
      return "phone.fill"
    case .active:
      return "phone.down.fill"
    default:
      return "phone.fill"
    }
  }
  
  private var buttonColor: Color {
    switch connectionState {
    case .connecting:
      return Color(red: 0.39, green: 0.27, blue: 0.92).opacity(0.7)
    case .active:
      return .red
    default:
      return Color(red: 0.39, green: 0.27, blue: 0.92)
    }
  }
  
  private var buttonText: String? {
    switch connectionState {
    case .connecting:
      return "Connecting..."
    default:
      return nil
    }
  }
  
  var body: some View {
    VStack(spacing: 12) {
      Button(action: action) {
        ZStack {
          Circle()
            .fill(buttonColor)
            .frame(width: 72, height: 72)
            .shadow(color: buttonColor.opacity(0.4), radius: 12, x: 0, y: 6)
          
          if connectionState == .connecting {
            ProgressView()
              .tint(.white)
              .scaleEffect(1.2)
          } else {
            Image(systemName: buttonIcon)
              .font(.system(size: 28, weight: .semibold))
              .foregroundColor(.white)
          }
        }
        .scaleEffect(isConnected ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isConnected)
      }
      .disabled(connectionState == .connecting)
      
      if let text = buttonText {
        Text(text)
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.gray)
          .transition(.opacity)
      } else if isConnected {
        Text("Tap to end")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.red)
          .transition(.opacity)
      } else {
        Text("Tap to start")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(Color(red: 0.39, green: 0.27, blue: 0.92))
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: connectionState)
    .animation(.easeInOut(duration: 0.2), value: isConnected)
  }
}

// MARK: - Types and Preview
struct Agent {
  let id: String
  let name: String
  let description: String
}

#Preview {
  ConversationalAIExampleView()
}


