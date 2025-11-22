//
//  ConversationAudioEngine.swift
//  prime
//
//  Created by Assistant on 11/20/25.
//

import Accelerate
import AVFoundation
import ElevenLabs
import LiveKit

final class ConversationAudioEngine: NSObject {
  static let shared = ConversationAudioEngine()
  
  private final class MicRenderer: NSObject, AudioRenderer, @unchecked Sendable {
    weak var owner: ConversationAudioEngine?
    
    func render(pcmBuffer: AVAudioPCMBuffer) {
      guard let owner else { return }
      let rms = owner.computeRMS(from: pcmBuffer)
      owner.enqueueMicLevel(rms: rms)
    }
  }
  
  private final class RemoteAudioProcessor: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    weak var owner: ConversationAudioEngine?
    private var processorFormat: AVAudioFormat?
    
    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
      let channelCount = max(1, channels)
      processorFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRateHz),
        channels: AVAudioChannelCount(channelCount),
        interleaved: false
      )
    }
    
    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
      guard let owner, let format = processorFormat else { return }
      
      let frames = AVAudioFrameCount(audioBuffer.frames)
      guard frames > 0 else { return }
      guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
      pcmBuffer.frameLength = frames
      guard let destination = pcmBuffer.floatChannelData else { return }
      
      for channel in 0..<Int(format.channelCount) {
        let sourceChannel = min(channel, audioBuffer.channels - 1)
        let sourcePointer = audioBuffer.rawBuffer(forChannel: sourceChannel)
        memcpy(destination[channel], sourcePointer, Int(frames) * MemoryLayout<Float>.size)
      }
      
      owner.handleRemoteBuffer(pcmBuffer)
      
      for channel in 0..<audioBuffer.channels {
        let pointer = audioBuffer.rawBuffer(forChannel: channel)
        memset(pointer, 0, Int(frames) * MemoryLayout<Float>.size)
      }
    }
    
    func audioProcessingRelease() {
      processorFormat = nil
    }
  }
  
  private let engine = AVAudioEngine()
  private let duckingMixer = AVAudioMixerNode()
  private let voiceNode = AVAudioPlayerNode()
  private let musicNode = AVAudioPlayerNode()
  
  private let micRenderer = MicRenderer()
  private let remoteProcessor = RemoteAudioProcessor()
  
  private var renderFormat: AVAudioFormat?
  private var musicLoopBuffer: AVAudioPCMBuffer?
  private var voiceConverter: AVAudioConverter?
  
  private let processingQueue = DispatchQueue(label: "com.prime.audio.conversation-engine")
  
  private let idleVolume: Float = 0.35
  private let aiSpeakingVolume: Float = 0.1
  private let micSpeakingVolume: Float = 0.10
  private let aiRmsThreshold: Float = 0.001
  private let micRmsThreshold: Float = 0.0015
  private let aiDbThreshold: Float = -60
  private let micDbThreshold: Float = -50
  
  private var aiLevel: Float = 0
  private var micLevel: Float = 0
  private var targetVolume: Float = 0.35
  private var currentVolume: Float = 0.35
  private var smoothingTimer: DispatchSourceTimer?
  private let voiceGateDelay: TimeInterval = 1.0
  private var voiceGateReady = false
  private var pendingVoiceBuffers: [(buffer: AVAudioPCMBuffer, rms: Float)] = []
  private var agentSpeaking = false
  
  private var isConfigured = false
  private var isRunning = false
  private var musicPlaying = false
  
  private override init() {
    super.init()
    micRenderer.owner = self
    remoteProcessor.owner = self
  }
  
  func startMusic() {
    processingQueue.async {
      if self.isRunning {
        self.stopLocked()
      }
      
      self.configureEngineIfNeeded()
      self.prepareMusicBufferIfNeeded()
      self.startEngineIfNeeded()
      self.configureSmoothingTimerIfNeeded()
      self.isRunning = true
      self.musicPlaying = true
    }
  }
  
  func attach(conversation _: Conversation) {
    processingQueue.async {
      guard self.isRunning else { return }
      self.installRenderers()
      self.prepareVoiceGate()
    }
  }
  
  func setAgentSpeaking(_ speaking: Bool) {
    processingQueue.async {
      self.agentSpeaking = speaking
      self.updateTargetVolume()
    }
  }
  
  func setVoiceVolume(_ volume: Float) {
    processingQueue.async {
      self.voiceNode.volume = volume
    }
  }
  
  func stop() {
    processingQueue.async {
      self.stopLocked()
    }
  }
}

// MARK: - Engine Lifecycle

private extension ConversationAudioEngine {
  func configureEngineIfNeeded() {
    guard !isConfigured else { return }
    
    let session = AVAudioSession.sharedInstance()
    let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
    let channels: AVAudioChannelCount = 2
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
      print("ConversationAudioEngine: Failed to create render format")
      return
    }
    
    renderFormat = format
    
    engine.attach(voiceNode)
    engine.attach(musicNode)
    engine.attach(duckingMixer)
    
    engine.connect(voiceNode, to: duckingMixer, format: format)
    engine.connect(musicNode, to: duckingMixer, format: format)
    engine.connect(duckingMixer, to: engine.mainMixerNode, format: format)
    
    duckingMixer.outputVolume = 1.0
    musicNode.volume = idleVolume
    currentVolume = idleVolume
    targetVolume = idleVolume
    
    isConfigured = true
  }
  
  func startEngineIfNeeded() {
    guard renderFormat != nil else { return }
    
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        print("ConversationAudioEngine: Failed to start engine - \(error)")
      }
    }
    
    restartMusicLoopIfNeeded()
    
    if !voiceNode.isPlaying {
      voiceNode.play()
    }
  }
  
  func restartMusicLoopIfNeeded() {
    guard let loopBuffer = musicLoopBuffer else { return }
    
    if musicNode.isPlaying {
      return
    }
    
    musicNode.stop()
    musicNode.scheduleBuffer(loopBuffer, at: nil, options: [.loops])
    musicNode.play()
    musicNode.volume = currentVolume
    musicPlaying = true
  }
  
  func stopLocked() {
    uninstallRenderers()
    
    voiceNode.stop()
    voiceNode.reset()
    
    musicNode.stop()
    musicNode.reset()
    musicPlaying = false
    
    if engine.isRunning {
      engine.stop()
    }
    
    smoothingTimer?.cancel()
    smoothingTimer = nil
    
    aiLevel = 0
    micLevel = 0
    targetVolume = idleVolume
    currentVolume = idleVolume
    musicNode.volume = idleVolume
    
    isRunning = false
  }
}

// MARK: - Renderer Management

private extension ConversationAudioEngine {
  func installRenderers() {
    AudioManager.shared.add(localAudioRenderer: micRenderer)
    AudioManager.shared.renderPreProcessingDelegate = remoteProcessor
  }
  
  func uninstallRenderers() {
    AudioManager.shared.remove(localAudioRenderer: micRenderer)
    if AudioManager.shared.renderPreProcessingDelegate != nil {
      AudioManager.shared.renderPreProcessingDelegate = nil
    }
    voiceConverter = nil
    pendingVoiceBuffers.removeAll()
    voiceGateReady = false
  }

  func prepareVoiceGate() {
    voiceGateReady = false
    pendingVoiceBuffers.removeAll()
    processingQueue.asyncAfter(deadline: .now() + voiceGateDelay) { [weak self] in
      guard let self, self.isRunning else { return }
      self.voiceGateReady = true
      self.flushPendingVoiceBuffers()
    }
  }
}

// MARK: - Buffer Handling

private extension ConversationAudioEngine {
  func prepareMusicBufferIfNeeded() {
    guard musicLoopBuffer == nil else { return }
    guard let url = Bundle.main.url(forResource: "BackgroundLoop", withExtension: "mp4") else {
      print("ConversationAudioEngine: BackgroundLoop.mp4 missing from bundle")
      return
    }
    
    do {
      let file = try AVAudioFile(forReading: url)
      guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        print("ConversationAudioEngine: Unable to create buffer for music file")
        return
      }
      
      try file.read(into: tempBuffer)
      guard let format = renderFormat else { return }
      guard let converted = convert(buffer: tempBuffer, to: format) else { return }
      
      musicLoopBuffer = converted
    } catch {
      print("ConversationAudioEngine: Failed to load music file - \(error)")
    }
  }
  
  func prepareVoicePlaybackBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let format = renderFormat else { return nil }
    
    if buffer.format == format {
      return clone(buffer)
    }
    
    if voiceConverter == nil || voiceConverter?.inputFormat != buffer.format {
      voiceConverter = AVAudioConverter(from: buffer.format, to: format)
    }
    
    guard let converter = voiceConverter else { return nil }
    return convert(buffer: buffer, using: converter, targetFormat: format)
  }
  
  func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
      return nil
    }
    
    copy.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
      guard
        let source = buffer.floatChannelData,
        let destination = copy.floatChannelData
      else {
        return nil
      }
      
      for channel in 0..<channelCount {
        memcpy(destination[channel], source[channel], frameCount * MemoryLayout<Float>.size)
      }
    case .pcmFormatInt16:
      guard
        let source = buffer.int16ChannelData,
        let destination = copy.int16ChannelData
      else {
        return nil
      }
      
      for channel in 0..<channelCount {
        memcpy(destination[channel], source[channel], frameCount * MemoryLayout<Int16>.size)
      }
    default:
      return nil
    }
    
    return copy
  }
  
  func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
      return nil
    }
    return convert(buffer: buffer, using: converter, targetFormat: format)
  }
  
  func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = max(1024, AVAudioFrameCount(Double(buffer.frameLength) * ratio))
    
    guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
      return nil
    }
    
    var isDone = false
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      if isDone {
        outStatus.pointee = .endOfStream
        return nil
      } else {
        isDone = true
        outStatus.pointee = .haveData
        return buffer
      }
    }
    
    var error: NSError?
    converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
    
    if let error {
      print("ConversationAudioEngine: Audio conversion error - \(error)")
      return nil
    }
    
    return converted
  }
}

// MARK: - Amplitude + Ducking

private extension ConversationAudioEngine {
  func handleRemoteBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let playbackBuffer = prepareVoicePlaybackBuffer(from: buffer) else { return }
    let rms = computeRMS(from: buffer)
    processingQueue.async {
      guard self.isRunning else { return }
      if self.voiceGateReady {
        self.enqueueVoiceUnlocked(buffer: playbackBuffer, rms: rms)
      } else {
        self.pendingVoiceBuffers.append((playbackBuffer, rms))
      }
    }
  }
  
  func enqueueVoiceUnlocked(buffer: AVAudioPCMBuffer, rms: Float) {
    guard isRunning else { return }
    
    aiLevel = lowPass(previous: aiLevel, newValue: rms)
    voiceNode.scheduleBuffer(buffer, at: nil, options: [])
    if !voiceNode.isPlaying {
      voiceNode.play()
    }
    
    updateTargetVolume()
  }
  
  func enqueueMicLevel(rms: Float) {
    processingQueue.async {
      guard self.isRunning else { return }
      self.micLevel = self.lowPass(previous: self.micLevel, newValue: rms)
      self.updateTargetVolume()
    }
  }
  
  func lowPass(previous: Float, newValue: Float, smoothing: Float = 0.3) -> Float {
    // Higher smoothing = more responsive
    let clampedNew = max(0, min(1, newValue))
    return previous * (1 - smoothing) + clampedNew * smoothing
  }
  
  func updateTargetVolume() {
    // More aggressive ducking logic with debug logging
    let aiDb = 20 * log10(max(aiLevel, 1e-7))
    let micDb = 20 * log10(max(micLevel, 1e-7))
    
    let aiActive = agentSpeaking || aiLevel > aiRmsThreshold || aiDb > aiDbThreshold
    let micActive = micLevel > micRmsThreshold || micDb > micDbThreshold
    
    // Debug logging
    if aiActive || micActive {
      print("🎵 Ducking: AI RMS=\(aiLevel) dB=\(aiDb) active=\(aiActive), Mic RMS=\(micLevel) dB=\(micDb) active=\(micActive)")
    }
    
    let desired: Float
    if aiActive {
      desired = aiSpeakingVolume
    } else if micActive {
      desired = micSpeakingVolume
    } else {
      desired = idleVolume
    }
    
    if abs(desired - targetVolume) > 0.001 {
      targetVolume = desired
    }
  }

  func flushPendingVoiceBuffers() {
    guard voiceGateReady else { return }
    if pendingVoiceBuffers.isEmpty { return }
    
    let buffers = pendingVoiceBuffers
    pendingVoiceBuffers.removeAll()
    for entry in buffers {
      enqueueVoiceUnlocked(buffer: entry.buffer, rms: entry.rms)
    }
  }
  
  func configureSmoothingTimerIfNeeded() {
    guard smoothingTimer == nil else { return }
    
    let timer = DispatchSource.makeTimerSource(queue: processingQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))  // Faster updates for smoother ducking
    timer.setEventHandler { [weak self] in
      self?.stepMusicVolume()
    }
    timer.resume()
    smoothingTimer = timer
  }
  
  func stepMusicVolume() {
    let diff = targetVolume - currentVolume
    if abs(diff) < 0.001 {
      currentVolume = targetVolume
    } else {
      // Faster ducking response
      let rate: Float = diff < 0 ? 0.5 : 0.15  // Duck quickly, recover slowly
      currentVolume += diff * rate
    }
    
    musicNode.volume = currentVolume
  }
  
  func computeRMS(from buffer: AVAudioPCMBuffer) -> Float {
    guard
      buffer.frameLength > 0,
      let channelData = buffer.floatChannelData
    else {
      return 0
    }
    
    let frames = vDSP_Length(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Use peak detection for more responsive ducking
    var maxPeak: Float = 0
    for channel in 0..<channelCount {
      var peak: Float = 0
      vDSP_maxmgv(channelData[channel], 1, &peak, frames)
      maxPeak = max(maxPeak, peak)
    }
    
    // Blend peak with RMS for hybrid detection
    var totalRMS: Float = 0
    for channel in 0..<channelCount {
      var meanSquare: Float = 0
      vDSP_measqv(channelData[channel], 1, &meanSquare, frames)
      totalRMS += meanSquare
    }
    totalRMS /= Float(max(channelCount, 1))
    let rms = sqrtf(totalRMS)
    
    // Weight peak detection more heavily for faster response
    return (maxPeak * 0.7) + (rms * 0.3)
  }
  
}

