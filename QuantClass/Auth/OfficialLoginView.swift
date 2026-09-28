import SwiftUI
import WebKit

struct OfficialLoginView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var controller = NativeQRLoginController()
    private let blue = Color(red: 24/255, green: 120/255, blue: 243/255)
    private let navy = Color(red: 7/255, green: 55/255, blue: 99/255)
    private let secondary = Color(red: 133/255, green: 144/255, blue: 166/255)

    var body: some View {
        NavigationStack {
            ZStack {
                // The live official page is mounted for its authentication lifecycle,
                // but never participates in the visible or accessible native interface.
                if !controller.showOfficialVerification {
                    OfficialQRWebView(controller: controller)
                    .frame(width: 390, height: 600)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Color.white.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        HStack(spacing: 10) {
                            Image("BrandLogo").resizable().frame(width: 218.5, height: 44)
                                .frame(width: 44, height: 44, alignment: .leading).clipped().accessibilityHidden(true)
                            Text("量化小论坛").font(.system(size: 18, weight: .semibold)).foregroundStyle(navy)
                        }
                        VStack(spacing: 10) {
                            Text("登录量化小论坛").font(.system(size: 23, weight: .semibold)).foregroundStyle(navy)
                            Text("使用微信扫码，继续浏览与收藏").font(.subheadline).foregroundStyle(secondary)
                        }
                        qrPanel.padding(.top, 8)
                        Label("打开微信扫一扫", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(navy)
                        Text(controller.message).font(.footnote).foregroundStyle(secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 20)
                        if controller.phase == .verification {
                            Button("完成官网验证") { controller.showOfficialVerification = true }
                                .font(.subheadline.weight(.medium)).foregroundStyle(blue).frame(minHeight: 44)
                        } else {
                            Button(controller.phase == .expired ? "刷新二维码" : controller.phase == .failed ? "重试" : "刷新二维码") {
                                controller.refresh()
                            }.font(.subheadline.weight(.medium)).foregroundStyle(blue).frame(minHeight: 44)
                                .disabled(controller.phase == .validating)
                        }
                        Text("登录状态仅保存在此设备").font(.caption).foregroundStyle(secondary).padding(.top, 16)
                    }.frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 30)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.stop(); session.showLogin = false } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(secondary)
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭登录")
                }
            }
            .toolbarBackground(.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $controller.showOfficialVerification) {
                NavigationStack {
                    OfficialQRWebView(controller: controller)
                        .navigationTitle("官网验证").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("返回") { controller.showOfficialVerification = false } } }
                }
            }
        }
        .preferredColorScheme(.light)
        .task { controller.start(session: session) }
        .onDisappear { controller.stop() }
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.white)
            if let image = controller.qrImage {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 220, height: 220)
                    .accessibilityLabel("微信登录二维码")
            } else if controller.phase == .loading {
                ProgressView().tint(blue)
            } else {
                Image(systemName: "qrcode").font(.system(size: 68, weight: .light)).foregroundStyle(secondary.opacity(0.3))
                    .accessibilityHidden(true)
            }
            if controller.phase == .expired || controller.phase == .failed || controller.phase == .validating {
                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.94))
                VStack(spacing: 12) {
                    if controller.phase == .validating { ProgressView().tint(blue); Text("正在验证登录…") }
                    else {
                        Image(systemName: controller.phase == .expired ? "arrow.clockwise" : "wifi.exclamationmark").font(.title2)
                        Text(controller.phase == .expired ? "二维码已过期" : "二维码加载失败")
                    }
                }.font(.subheadline).foregroundStyle(navy)
            }
        }
        .frame(width: 260, height: 260)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 235/255, green: 238/255, blue: 242/255), lineWidth: 1))
    }
}

private struct OfficialQRWebView: UIViewRepresentable {
    @ObservedObject var controller: NativeQRLoginController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
