import Foundation
import SwiftParser
import SwiftSyntax
struct Entry: Codable { var file:String;var start:Int;var end:Int;var key:String;var literal:String;var raw:Bool;var context:String }
final class Strings:SyntaxVisitor {
 var entries:[Entry]=[];var file:String
 init(file:String){self.file=file;super.init(viewMode:.sourceAccurate)}
 override func visit(_ node:StringLiteralExprSyntax)->SyntaxVisitorContinueKind {
  let source=node.trimmedDescription
  guard source.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{return .visitChildren}
  var key="";var index=0
  for segment in node.segments {
   if let part=segment.as(StringSegmentSyntax.self) {
    // Ask SwiftParser to decode escapes using a standalone literal.
    let standalone=(node.openingPounds?.description ?? "")+node.openingQuote.description+part.content.text+node.closingQuote.description+(node.closingPounds?.description ?? "")
    let tree=Parser.parse(source:standalone)
    if let expr=tree.statements.first?.item.as(ExprSyntax.self)?.as(StringLiteralExprSyntax.self),let value=expr.representedLiteralValue {key+=value}else{key+=part.content.text}
   } else {key+="{\(index)}";index+=1}
  }
  var parent=node.parent;var raw=false;var context:[String]=[]
  for _ in 0..<6 {guard let p=parent else{break};context.append("\(p.kind):"+p.trimmedDescription.prefix(180));if p.is(EnumCaseElementSyntax.self){raw=true};parent=p.parent}
  entries.append(Entry(file:file,start:node.positionAfterSkippingLeadingTrivia.utf8Offset,end:node.endPositionBeforeTrailingTrivia.utf8Offset,key:key,literal:source,raw:raw,context:context.joined(separator:" | ")))
  return .visitChildren
 }
}
var entries:[Entry]=[]
for path in CommandLine.arguments.dropFirst(){let v=Strings(file:path);v.walk(Parser.parse(source:try String(contentsOfFile:path,encoding:.utf8)));entries+=v.entries}
let data=try JSONEncoder().encode(entries);FileHandle.standardOutput.write(data)
