//
//  ContentView.swift
//  DDD
//
//  Вьюпорт на всё окно, панели плавают поверх.
//

import SwiftUI

struct ContentView: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
            Color.black.opacity(0.55)
            ViewportView(model: model)

            // Полоса под заголовком: за неё можно таскать окно.
            Color.clear
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            panels
        }
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.25), value: model.toast)
    }

    private var panels: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                TreePanel(model: model)
                Spacer(minLength: 16)
                if !model.selection.isEmpty {
                    InspectorPanel(model: model)
                        // Под кубом навигации.
                        .padding(.top, ViewCubeView.size - 32)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, 52)
            .padding(.horizontal, 14)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            ToolbarView(model: model)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            ViewCubeView(model: model)
                .padding(.top, 12)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            StatusView(model: model)
                .padding(.trailing, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            Group {
                if let toast = model.toast {
                    ToastView(model: model, toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
