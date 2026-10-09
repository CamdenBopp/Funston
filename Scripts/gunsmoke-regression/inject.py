from pathlib import Path
import re, sys
root=Path(sys.argv[1])
app='Funston' if (root/'Funston').exists() else 'Archive'
f=root/app/'Services/PlaybackController.swift'
s=f.read_text()
diag='''
    private func startGunsmokeRegressionDiagnostics() {
        guard ProcessInfo.processInfo.arguments.contains("--gunsmoke-regression") else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("gunsmoke-playback.jsonl")
        try? Data().write(to: url)
        Task { @MainActor [weak self] in
            for _ in 0..<300 {
                guard let self else { return }
                let item = self.player.currentItem
                let session = AVAudioSession.sharedInstance()
                let snapshot: [String: Any] = [
                    "timestamp": Date().timeIntervalSince1970,
                    "phase": self.phase.spokenValue,
                    "seconds": self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : -1,
                    "rate": self.player.rate,
                    "volume": self.player.volume,
                    "muted": self.player.isMuted,
                    "artworkLoaded": self.nowPlayingArtwork != nil,
                    "assetURL": (item?.asset as? AVURLAsset)?.url.absoluteString ?? "",
                    "itemStatus": item?.status.rawValue ?? -1,
                    "transport": self.player.timeControlStatus.rawValue,
                    "waitingReason": self.player.reasonForWaitingToPlay?.rawValue ?? "",
                    "error": item?.error?.localizedDescription ?? "",
                    "file": self.context?.file.name ?? "",
                    "identifier": self.context?.artifact.identifier ?? "",
                    "bytes": item?.accessLog()?.events.reduce(Int64(0)) { $0 + $1.numberOfBytesTransferred } ?? 0,
                    "errors": item?.errorLog()?.events.map { "\\($0.errorDomain):\\($0.errorStatusCode):\\($0.errorComment ?? "")" } ?? [],
                    "category": session.category.rawValue,
                    "outputVolume": session.outputVolume,
                    "route": session.currentRoute.outputs.map { $0.portType.rawValue + ":" + $0.portName }
                ]
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
                   let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10])); try? handle.close()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
'''
# Insert at the end of the initializer, immediately before deinit.
m=re.search(r'\n    }\n\n    (?:isolated )?deinit',s)
assert m, 'initializer boundary missing'
s=s[:m.start()]+'\n        startGunsmokeRegressionDiagnostics()'+s[m.start():]
pos=s.index('\n    func load(')
s=s[:pos]+diag+s[pos:]
f.write_text(s)
test=root/(app+'UITests')/(app+'UITests.swift')
harness=Path(__file__).with_name('GunsmokeUITest.swift').read_text().replace('REGRESSION_CLASS',app+'UITests')
for p in test.parent.glob('*.swift'): p.write_text('import XCTest\n')
test.write_text(harness)
# This historical audit runs only the UI target. Keep unit tests in the real scheme.
import xml.etree.ElementTree as ET
scheme=root/(app+'.xcodeproj')/'xcshareddata/xcschemes'/(app+'.xcscheme')
tree=ET.parse(scheme)
for testables in tree.getroot().findall('./TestAction/Testables'):
 for ref in list(testables):
  build=ref.find('BuildableReference')
  if build is not None and 'UITests' not in build.get('BlueprintName',''): testables.remove(ref)
tree.write(scheme,encoding='utf-8',xml_declaration=True)
# Preserve unchanged inputs, but never give changed historical sources a timestamp
# older than compiler output. Otherwise Xcode can reuse incompatible Swift objects.
import os, time
previous=Path('/tmp/funston-gunsmoke-history')
if root.name == 'funston-gunsmoke-staging':
 for path in root.rglob('*'):
  if not path.is_file(): continue
  prior=previous/path.relative_to(root)
  same=prior.is_file() and prior.read_bytes()==path.read_bytes()
  timestamp=prior.stat().st_mtime if same else time.time()
  os.utime(path,(timestamp,timestamp))
print(app)
