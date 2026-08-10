import SwiftUI
import WebKit
import QuickLook

// Обертка для URL, чтобы он соответствовал протоколу Identifiable
struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct DownloadedFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let size: String
    let date: Date
}

struct ContentView: View {
    @StateObject private var webModel = WebViewModel()
    @State private var urlString = "https://www.google.com"
    @State private var showDownloadsList = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { webModel.webView.goBack() }) {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!webModel.canGoBack)
                    
                    Button(action: { webModel.webView.goForward() }) {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!webModel.canGoForward)
                    
                    TextField("Введите URL...", text: $urlString, onCommit: {
                        webModel.load(urlString: urlString)
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    
                    Button(action: { webModel.webView.reload() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    
                    Button(action: { showDownloadsList.toggle() }) {
                        Image(systemName: "folder")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                if webModel.isLoading {
                    ProgressView(value: webModel.estimatedProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .frame(height: 2)
                } else {
                    Spacer().frame(height: 2)
                }
                
                WebViewContainer(webModel: webModel)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showDownloadsList) {
                DownloadsManagerView(webModel: webModel)
            }
            .overlay(
                VStack {
                    if let status = webModel.downloadStatusMessage {
                        Text(status)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.8)))
                            .foregroundColor(.white)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, 10)
                    }
                    Spacer()
                }
                .animation(.easeInOut, value: webModel.downloadStatusMessage)
            )
        }
        .onAppear {
            webModel.load(urlString: urlString)
        }
    }
}

class WebViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKDownloadDelegate {
    @Published var webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0.0
    
    @Published var downloadedFiles: [DownloadedFile] = []
    @Published var downloadStatusMessage: String?
    
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    
    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        
        self.webView.navigationDelegate = self
        setupKVO()
        fetchDownloadedFiles()
    }
    
    private func setupKVO() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.estimatedProgress = webView.estimatedProgress
            }
        }
        
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.isLoading = webView.isLoading
            }
        }
    }
    
    func load(urlString: String) {
        var formattedString = urlString
        if !formattedString.hasPrefix("http://") && !formattedString.hasPrefix("https://") {
            formattedString = "https://" + formattedString
        }
        if let url = URL(string: formattedString) {
            webView.load(URLRequest(url: url))
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.canGoBack = webView.canGoBack
        self.canGoForward = webView.canGoForward
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
        } else {
            decisionHandler(.allow, preferences)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }
    
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        showNotification("Загрузка началась...")
    }
    
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        showNotification("Загрузка началась...")
    }
    
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = docs.appendingPathComponent(suggestedFilename)
        completionHandler(destinationURL)
    }
    
    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            self.showNotification("Файл успешно скачан!")
            self.fetchDownloadedFiles()
        }
    }
    
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            self.showNotification("Ошибка скачивания: \(error.localizedDescription)")
        }
    }
    
    func fetchDownloadedFiles() {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: .skipsHiddenFiles)
            
            self.downloadedFiles = fileURLs.map { url in
                let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
                let fileSize = attributes[.size] as? Int64 ?? 0
                let creationDate = attributes[.creationDate] as? Date ?? Date()
                
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let sizeString = formatter.string(fromByteCount: fileSize)
                
                return DownloadedFile(name: url.lastPathComponent, url: url, size: sizeString, date: creationDate)
            }.sorted(by: { $0.date > $1.date })
        } catch {
            print("Ошибка чтения директории: \(error)")
        }
    }
    
    func deleteFile(at offsets: IndexSet) {
        let fileManager = FileManager.default
        for index in offsets {
            let file = downloadedFiles[index]
            try? fileManager.removeItem(at: file.url)
        }
        downloadedFiles.remove(atOffsets: offsets)
    }
    
    private func showNotification(_ message: String) {
        downloadStatusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.downloadStatusMessage == message {
                self.downloadStatusMessage = nil
            }
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var webModel: WebViewModel
    
    func makeUIView(context: Context) -> WKWebView {
        return webModel.webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DownloadsManagerView: View {
    @ObservedObject var webModel: WebViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var previewItem: PreviewItem?
    
    var body: some View {
        NavigationView {
            List {
                if webModel.downloadedFiles.isEmpty {
                    Text("Скачанных файлов нет")
                        .foregroundColor(.gray)
                } else {
                    ForEach(webModel.downloadedFiles) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                
                                HStack {
                                    Text(file.size)
                                    Text("•")
                                    Text(file.date, style: .date)
                                }
                                .font(.caption)
                                .foregroundColor(.gray)
                            }
                            Spacer()
                            
                            Button(action: {
                                previewItem = PreviewItem(url: file.url)
                            }) {
                                Image(systemName: "eye")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .onDelete(perform: webModel.deleteFile)
                }
            }
            .navigationTitle("Загрузки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(item: $previewItem) { item in
                FilePreviewController(url: item.url)
            }
        }
    }
}

struct FilePreviewController: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: FilePreviewController
        
        init(parent: FilePreviewController) {
            self.parent = parent
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }
    }
}