import Foundation

struct MihonRepositoryService: Sendable {
    let http: any MihonHTTPFetching

    init(http: any MihonHTTPFetching = MihonHTTPClient()) {
        self.http = http
    }

    func normalizeIndexURL(_ input: String) throws -> URL {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MihonError.invalidRepositoryURL(input)
        }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https" else {
            throw MihonError.invalidRepositoryURL(input)
        }

        let path = components.path
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last.hasSuffix(".pb") || last.hasSuffix(".json") || last.hasSuffix(".json.gz") {
            guard let url = components.url else {
                throw MihonError.invalidRepositoryURL(input)
            }
            return url
        }

        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.path += "index.pb"
        guard let url = components.url, url.host() != nil else {
            throw MihonError.invalidRepositoryURL(input)
        }
        return url
    }

    func fetchIndex(
        at indexURL: URL,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws -> (index: MihonIndex, etag: String?, lastModified: String?, unchanged: Bool) {
        var headers: [String: String] = [:]
        if let etag, !etag.isEmpty {
            headers["If-None-Match"] = etag
        }
        if let lastModified, !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }

        let response = try await http.fetch(
            MihonHTTPRequest(url: indexURL, headers: headers)
        )
        if response.statusCode == 304 {
            return (MihonIndex(), response.headers["etag"] ?? etag, response.headers["last-modified"] ?? lastModified, true)
        }
        guard response.isSuccess else {
            throw MihonError.httpStatus(response.statusCode)
        }
        guard response.url.scheme?.lowercased() == "https" else {
            throw MihonError.invalidRepositoryURL(response.url.absoluteString)
        }
        guard response.data.count <= MihonIndexDecoder.maximumIndexBytes else {
            throw MihonError.indexTooLarge(response.data.count)
        }

        var index = try MihonIndexDecoder.decode(response.data, indexURL: indexURL)
        if index.extensions.isEmpty, let listURL = index.extensionListURL {
            let listResponse = try await http.fetch(MihonHTTPRequest(url: listURL))
            guard listResponse.isSuccess else {
                throw MihonError.httpStatus(listResponse.statusCode)
            }
            let listIndex = try MihonIndexDecoder.decode(listResponse.data, indexURL: listURL)
            index.extensions = listIndex.extensions
        }
        return (
            index,
            response.headers["etag"],
            response.headers["last-modified"],
            false
        )
    }

    func makeRepository(indexURL: URL, repositoryID: UUID = UUID()) async throws -> MihonRepository {
        let fetched = try await fetchIndex(at: indexURL)
        guard !fetched.unchanged else {
            throw MihonError.invalidIndex("The server returned 304 for a new repository.")
        }
        return MihonRepository(
            id: repositoryID,
            indexURL: indexURL,
            name: fetched.index.name,
            badgeLabel: fetched.index.badgeLabel,
            signingKey: fetched.index.signingKey,
            contactWebsite: fetched.index.contact?.website,
            contactDiscord: fetched.index.contact?.discord,
            extensions: fetched.index.extensions,
            fetchedAt: .now,
            etag: fetched.etag,
            lastModified: fetched.lastModified
        )
    }

    func refresh(_ repository: MihonRepository) async throws -> MihonRepository {
        let fetched = try await fetchIndex(
            at: repository.indexURL,
            etag: repository.etag,
            lastModified: repository.lastModified
        )
        if fetched.unchanged {
            var unchanged = repository
            unchanged.fetchedAt = .now
            return unchanged
        }

        let newKey = fetched.index.signingKey
        if !repository.signingKey.isEmpty,
           !newKey.isEmpty,
           normalizeKey(repository.signingKey) != normalizeKey(newKey) {
            throw MihonError.signingKeyChanged(normalizeKey(newKey))
        }

        return MihonRepository(
            id: repository.id,
            indexURL: repository.indexURL,
            name: fetched.index.name,
            badgeLabel: fetched.index.badgeLabel,
            signingKey: newKey.isEmpty ? repository.signingKey : newKey,
            contactWebsite: fetched.index.contact?.website,
            contactDiscord: fetched.index.contact?.discord,
            extensions: fetched.index.extensions,
            fetchedAt: .now,
            etag: fetched.etag,
            lastModified: fetched.lastModified
        )
    }

    func fetchAPK(
        for extensionValue: MihonExtension,
        repository: MihonRepository
    ) async throws -> Data {
        guard !repository.signingKey.isEmpty else {
            throw MihonError.untrustedRepository
        }
        let response = try await http.fetch(
            MihonHTTPRequest(url: extensionValue.apkURL)
        )
        guard response.isSuccess else {
            throw MihonError.httpStatus(response.statusCode)
        }
        guard response.data.count <= MihonAPKVerifier.maxAPKBytes else {
            throw MihonError.apkTooLarge(response.data.count)
        }
        return response.data
    }

    private func normalizeKey(_ value: String) -> String {
        value.lowercased().filter(\.isHexDigit)
    }
}
