import Foundation

extension RemoteMangaEntry {
    init(
        packageName: String,
        source: MihonSource,
        manga: MihonManga,
        addedAt: Date = .now
    ) {
        self.init(
            packageName: packageName,
            sourceID: source.id,
            sourceName: source.name,
            sourceLanguage: source.language,
            mangaID: manga.id,
            title: manga.title,
            coverURL: manga.coverURL,
            coverHeaders: manga.coverHeaders,
            author: manga.author,
            artist: manga.artist,
            description: manga.description,
            status: manga.status,
            genres: manga.genres,
            addedAt: addedAt
        )
    }

    var manga: MihonManga {
        MihonManga(
            id: mangaID,
            title: title,
            coverURL: coverURL,
            coverHeaders: coverHeaders,
            description: description,
            author: author,
            artist: artist,
            status: status,
            genres: genres,
            language: sourceLanguage
        )
    }
}
