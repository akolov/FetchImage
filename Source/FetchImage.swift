// The MIT License (MIT)
//
// Copyright (c) 2020 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Nuke

/// - WARNING: This is an API preview. It is not battle-tested yet and might signficantly change in the future.
public final class FetchImage: ObservableObject, Identifiable {
    /// The original request.
    public private(set) var request: ImageRequest?

    /// The request to be performed if the original request fails with
    /// `networkUnavailableReason` `.constrained` (low data mode).
    public private(set) var lowDataRequest: ImageRequest?

    /// Returns the fetched image.
    ///
    /// - note: In case pipeline has `isProgressiveDecodingEnabled` option enabled
    /// and the image being downloaded supports progressive decoding, the `image`
    /// might be updated multiple times during the download.
    @Published public private(set) var image: PlatformImage?

    /// Returns an error if the previous attempt to fetch the image failed with an error.
    /// Error is cleared out when the download is restarted.
    @Published public private(set) var error: Error?

    /// Returns `true` if the image is being loaded.
    @Published public private(set) var isLoading: Bool = false

    public struct Progress {
        /// The number of bytes that the task has received.
        public let completed: Int64

        /// A best-guess upper bound on the number of bytes the client expects to send.
        public let total: Int64
    }

    /// The progress of the image download.
    @Published public var progress = Progress(completed: 0, total: 0)

    /// Updates the priority of the task, even if the task is already running.
    public var priority: ImageRequest.Priority = .normal {
        didSet { task?.priority = priority }
    }

    private let pipeline: ImagePipeline
    private var task: ImageTask?
    private var loadedImageQuality: ImageQuality? = nil

    private enum ImageQuality {
        case regular, low
    }

    deinit {
        cancel()
    }

    /// Initializes specifying image pipeline.
    public init(pipeline: ImagePipeline = .shared) {
        self.pipeline = pipeline
    }

    /// Starts loading the image from image request.
    public func fetch(request: ImageRequest?, lowDataRequest: ImageRequest? = nil) {
        if request?.urlRequest.url != self.request?.urlRequest.url || lowDataRequest?.urlRequest.url != self.lowDataRequest?.urlRequest.url {
            cancel()
        }

        self.request = request
        self.lowDataRequest = lowDataRequest
        self.priority = request?.priority ?? .normal

        self.fetch()
    }

    /// Starts loading from regular URL.
    public func fetch(url: URL?) {
        if url != self.request?.urlRequest.url {
            cancel()
        }

        self.fetch(request: url.map { ImageRequest(url: $0) })
    }

    /// Fetches the image with a regular URL with
    /// constrained network access disabled, and if the download fails because of
    /// the constrained network access, uses a low data URL instead.
    public func fetch(regularUrl: URL, lowDataUrl: URL) {
        if regularUrl != self.request?.urlRequest.url || lowDataUrl != self.lowDataRequest?.urlRequest.url {
            cancel()
        }

        var request = URLRequest(url: regularUrl)
        request.allowsConstrainedNetworkAccess = false

        self.fetch(request: ImageRequest(urlRequest: request), lowDataRequest: ImageRequest(url: lowDataUrl))
    }

    /// Starts loading the image if not already loaded and the download is not
    /// already in progress.
    ///
    /// - note: Low Data Mode. If the `lowDataRequest` is provided and the regular
    /// request fails because of the constrained network access, the fetcher tries
    /// to download the low-quality image. The fetcher always tries to get the high
    /// quality image. If the first attempt fails, the next time you call `fetch`,
    /// it is going to attempt to fetch the regular quality image again.
    private func fetch() {
        guard
            let request = request,
            !isLoading,
            loadedImageQuality != .regular else {
                return
        }

        error = nil

        // Try to display the regular image if it is available in memory cache
        if let container = pipeline.cachedImage(for: request) {
            (image, loadedImageQuality) = (container.image, .regular)
            return // Nothing to do
        }

        // Try to display the low data image and retry loading the regular image
        if let container = lowDataRequest.flatMap(pipeline.cachedImage(for:)) {
            (image, loadedImageQuality) = (container.image, .low)
        }

        isLoading = true
        loadImage(request: request, quality: .regular)
    }

    private func loadImage(request: ImageRequest, quality: ImageQuality) {
        progress = Progress(completed: 0, total: 0)

        task = pipeline.loadImage(
            with: request,
            progress: { [weak self] response, completed, total in
                guard let self = self else { return }

                self.progress = Progress(completed: completed, total: total)

                if let image = response?.image {
                    self.image = image // Display progressively decoded image
                }
            },
            completion: { [weak self] in
                self?.didFinishRequest(result: $0, quality: quality)
            }
        )

        if priority != request.priority {
            task?.priority = priority
        }
    }

    private func didFinishRequest(result: Result<ImageResponse, ImagePipeline.Error>, quality: ImageQuality) {
        task = nil

        switch result {
        case let .success(response):
            isLoading = false
            (image, loadedImageQuality) = (response.image, quality)
        case let .failure(error):
            // If the regular request fails because of the low data mode,
            // use an alternative source.
            if quality == .regular, error.isConstrainedNetwork, let request = self.lowDataRequest {
                if loadedImageQuality == .low {
                    isLoading = false // Low-quality image already loaded
                } else {
                    loadImage(request: request, quality: .low)
                }
            } else {
                self.error = error
                isLoading = false
            }
        }
    }

    /// Marks the request as being cancelled.
    public func cancel() {
        task?.cancel() // Guarantees that no more callbacks are will be delivered
        task = nil
        isLoading = false
    }
}

private extension ImagePipeline.Error {
    var isConstrainedNetwork: Bool {
        if case let .dataLoadingFailed(error) = self,
            (error as? URLError)?.networkUnavailableReason == .constrained {
            return true
        }
        return false
    }
}

public extension FetchImage {
    var view: SwiftUI.Image? {
        #if os(macOS)
        return image.map(Image.init(nsImage:))
        #else
        return image.map(Image.init(uiImage:))
        #endif
    }
}
