from pathlib import Path
import hashlib
import json
import sys
root=Path(sys.argv[1])
store=(root/'Sources/LocalStorage/LocalStore.swift').read_text()
bookmark=(root/'Sources/LocalStorage/LocalStore+Bookmark.swift').read_text()
model=(root/'Sources/LocalStorage/TabDataModel/TabDataModel.swift').read_text()
def block(text, signature):
    start=text.index(signature); end=text.index('{',start)+1; depth=1
    while depth:
        depth += (text[end]=='{')-(text[end]=='}'); end+=1
    return text[start:end]
methods=[block(store,s) for s in ['    func updateLastSeen(', '    func performBackgroundWrite(',
    '    static func notificationContainsChanges(', '    static func tabType(']]
methods+=['    @MainActor\n'+block(bookmark,'    func bookmarksPublisher(')]
fifo_start=store.index('            let actor = LocalStoreActor(')
fifo_end=store.index('\n            do {',fifo_start)
parts={'PRODUCTION_TYPES':block(model,'enum TabDataType:')+'\nextension TabDataModel {\n'+block(model,'    var dataType:')+'\n}',
       'PRODUCTION_ACTOR':block(store,'@ModelActor\nactor LocalStoreActor'),
       'PRODUCTION_FIFO_SETUP':store[fifo_start:fifo_end].replace('let actor = LocalStoreActor(modelContainer: modelContainer)', 'let actor = suppliedWriter ?? LocalStoreActor(modelContainer: container)'),
       'PRODUCTION_METHODS':'\n'.join(methods)}
parts['PRODUCTION_BOOKMARK_EVIDENCE'] = bookmark[bookmark.index('private final class BookmarkSaveEvidence'):] if 'private final class BookmarkSaveEvidence' in bookmark else ''
manager=(root/'Sources/UserInterface/Sidebar/TabList/BookmarkModel.swift').read_text()
parts['PRODUCTION_VISIT_PROJECTION'] = block(manager, '    private func applyLastSeenUpdates(')
text=(root/'Tests/BookmarkNotifications/main.swift').read_text()
for key,value in parts.items():text=text.replace('/* '+key+' */',value)
text += '\n' + (root/'Tests/BookmarkNotifications/Background.swift').read_text()
Path(sys.argv[2]).write_text(text)
Path(sys.argv[2]).with_suffix('.provenance.json').write_text(json.dumps({k: hashlib.sha256(v.encode()).hexdigest() for k, v in parts.items()}, indent=2) + '\n')
