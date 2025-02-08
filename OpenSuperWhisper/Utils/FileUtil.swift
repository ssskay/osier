import Foundation

class FileUtil {

    static func copyFileToRecordsFolder(url: URL, fileName: String) -> URL {
        
        //  let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        // let recordingsDirectory = appDirectory.appendingPathComponent("recordings")
        // return recordingsDirectory.appendingPathComponent(fileName)

        let fileManager = FileManager.default
        let recordsFolder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let destinationURL = recordsFolder.appendingPathComponent(fileName)
        try! fileManager.copyItem(at: url, to: destinationURL)

        return destinationURL
    }

}
