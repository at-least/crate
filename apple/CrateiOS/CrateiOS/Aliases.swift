import Foundation
import CrateCore

// Foundation.Scanner 與 CrateCore.Scanner 撞名——App 層模組級 typealias 統一消歧。
typealias Track = CrateCore.Scanner.Track
typealias Album = CrateCore.Scanner.Album
