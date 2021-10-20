import Foundation
import ApolloUtils
import OrderedCollections

class SelectionSetScope: CustomDebugStringConvertible {
  typealias Selection = CompilationResult.Selection
  typealias Field = CompilationResult.Field

  weak var parent: SelectionSetScope?

  private(set) var children: [SelectionSetScope] = []

  let type: GraphQLCompositeType

  let selections: OrderedSet<Selection>

  convenience init(selectionSet: CompilationResult.SelectionSet, parent: SelectionSetScope?) {
    self.init(selections: selectionSet.selections,
              type: selectionSet.parentType,
              parent: parent)
  }

  init(selections: [Selection], type: GraphQLCompositeType, parent: SelectionSetScope?) {
    self.parent = parent
    self.type = type
    self.selections = OrderedSet(selections)
    computeChildren()
  }

  private func computeChildren() {
    self.children = selections.compactMap {
      switch $0 {
      case let .inlineFragment(fragment):
        return SelectionSetScope(selectionSet: fragment.selectionSet, parent: self)

      case let .fragmentSpread(fragment):
        if fragment.fragment.type == self.type { return nil }

        if let implementingType = self.type as? GraphQLInterfaceImplementingType,
           let fragmentInterface = fragment.fragment.type as? GraphQLInterfaceType,
           implementingType.implements(fragmentInterface) {
          return nil
        }

        #warning("TODO: selections should replace the fragmentSpread w/type case? (Or just check type again when generating selections?)")
        return SelectionSetScope(
          selections: [.fragmentSpread(fragment)],
          type: fragment.fragment.type,
          parent: self)

      default:
        return nil
      }
    }
  }

  /// All of the selections on the selection set that are fields. Does not traverse children.
  lazy var fieldSelections: [Selection] = {
    selections.compactMap {
      switch $0.self {
      case .field: return $0
      default: return nil
      }
    }
  }()

  lazy var mergedSelections: MergedSelections = {
    var selections = MergedSelections(selections)

    if let parentMergedSelections = selectionsToMerge(fromParent: parent) {
      selections.mergeIn(parentMergedSelections)
    }

    return selections
  }()

  private func selectionsToMerge(fromParent parent: SelectionSetScope?) -> [Selection]? {
    guard let parent = parent else { return nil }
    var selections: [Selection] = parent.fieldSelections

    if let recursiveParentSelections = selectionsToMerge(fromParent: parent.parent) {
      selections = recursiveParentSelections + selections
    }

    for sibling in parent.children {
      selections.append(contentsOf: selectionsToMerge(fromSibling: sibling))
    }

    return selections
  }

  private func selectionsToMerge(fromSibling other: SelectionSetScope) -> [Selection] {
    guard other !== self else { return [] }
    
    switch (self.type, other.type) {
    case let (selfType as GraphQLObjectType, otherType as GraphQLObjectType)
      where selfType.name == otherType.name:
      return other.fieldSelections + other.children.flatMap { self.selectionsToMerge(fromSibling: $0) }

    case let (selfType as GraphQLObjectType, otherType as GraphQLInterfaceType)
      where selfType.interfaces.contains { $0.name == otherType.name }:
      return other.fieldSelections

    case (is GraphQLObjectType, is GraphQLUnionType):
      return other.children.flatMap { self.selectionsToMerge(fromSibling: $0) }
//
//
//    case let (selfType as GraphQLInterfaceType, otherType as GraphQLObjectType):
//      return otherType.interfaces.contains { $0.name == selfType.name }
//
    case let (selfType as GraphQLInterfaceType, otherType as GraphQLInterfaceType)
      where selfType.interfaces.contains { $0.name == otherType.name }:
      return other.fieldSelections

//    case let (selfType as GraphQLUnionType, otherType as GraphQLObjectType):
//      return other.children.flatMap { self.selectionsToMerge(from: $0) }

    default: return []
    }
  }

  var debugDescription: String {
    var desc = type.debugDescription
    if !children.isEmpty {
      desc += " {"
      children.forEach { child in
        desc += "\n  \(indented: child.debugDescription)"
      }
      desc += "\n\(indented: "}")"
    }
    return desc
  }
}

//fileprivate protocol SelectionMergeable: GraphQLCompositeType {
//  var shouldMergeFieldsOfType
//}

struct MergedSelections: Equatable {
  typealias Selection = CompilationResult.Selection
  typealias Field = CompilationResult.Field
  typealias TypeCase = CompilationResult.InlineFragment
  typealias Fragment = CompilationResult.FragmentDefinition

  fileprivate(set) var fields: OrderedSet<Field> = []
  fileprivate(set) var typeCases: OrderedSet<TypeCase> = []
  fileprivate(set) var fragments: OrderedSet<Fragment> = []

  mutating func mergeIn(_ selections: [Selection]) {
    for selection in selections {
      switch selection {
      case let .field(field):
        fields.append(field)
      case let .inlineFragment(fragment):
        typeCases.append(fragment)
      case let .fragmentSpread(fragment):
        fragments.append(fragment.fragment)
      }
    }
  }

  init() {}

  init(
    fields: OrderedSet<Field> = [],
    typeCases: OrderedSet<TypeCase> = [],
    fragments: OrderedSet<Fragment> = []
  ) {
    self.fields = fields
    self.typeCases = typeCases
    self.fragments = fragments
  }

  init(_ selections: [CompilationResult.Selection]) {
    mergeIn(selections)
  }

  init(_ selections: OrderedSet<CompilationResult.Selection>) {
    mergeIn(selections.elements)
  }

  var isEmpty: Bool {
    fields.isEmpty && typeCases.isEmpty && fragments.isEmpty
  }

  static func ==(lhs: MergedSelections, rhs: MergedSelections) -> Bool {
    lhs.fields == rhs.fields &&
    lhs.typeCases == rhs.typeCases &&
    lhs.fragments == rhs.fragments
  }
}
