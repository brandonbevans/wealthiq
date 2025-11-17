//
//  CoachingStyleSelectionView.swift
//  wealthiq
//
//  Recreated after splitting from the old CoachingAndAccountabilityViews file.
//

import SwiftUI

struct CoachingStyleSelectionView: View {
  @ObservedObject var viewModel: OnboardingViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("What kind of coaching do you respond to best?")
        .font(.lora(24, weight: .semiBold))
        .foregroundColor(Color(red: 0.13, green: 0.06, blue: 0.16))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 12) {
        ForEach(viewModel.coachingStyleOptions, id: \.rawValue) { style in
          SelectionPill(
            title: style.rawValue,
            isSelected: viewModel.selectedCoachingStyle == style
          ) {
            withAnimation(.easeInOut(duration: 0.2)) {
              viewModel.selectCoachingStyle(style)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
              if viewModel.currentStep == .coachingStyle {
                withAnimation {
                  viewModel.nextStep()
                }
              }
            }
          }
        }
      }
    }
  }
}

private struct SelectionPill: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  private var selectedGradient: LinearGradient {
    LinearGradient(
      colors: [
        Color(red: 0.87, green: 0.79, blue: 1.0),
        Color(red: 0.78, green: 0.69, blue: 0.99)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.outfit(16, weight: .medium))
        .foregroundColor(Color(red: 0.13, green: 0.06, blue: 0.16))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
          RoundedRectangle(cornerRadius: 80)
            .fill(isSelected ? AnyShapeStyle(selectedGradient) : AnyShapeStyle(Color.white.opacity(0.97)))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 80)
            .stroke(
              isSelected
                ? Color(red: 0.52, green: 0.36, blue: 0.94).opacity(0.7)
                : Color(red: 0.93, green: 0.93, blue: 0.93),
              lineWidth: 1
            )
        )
        .shadow(
          color: isSelected ? Color(red: 0.4, green: 0.27, blue: 0.91).opacity(0.18) : Color.clear,
          radius: 18,
          x: 0,
          y: 10
        )
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  CoachingStyleSelectionView(viewModel: OnboardingViewModel())
    .padding(20)
    .background(Color.white)
}


