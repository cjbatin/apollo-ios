import JavaScriptCore

/// The output of the frontend compiler.
public class CompilationResult: JavaScriptObject {
  lazy var operations: [OperationDefinition] = self["operations"]
  
  lazy var fragments: [FragmentDefinition] = self["fragments"]

  lazy var referencedTypes: [GraphQLNamedType] = self["referencedTypes"]
  
  public class OperationDefinition: JavaScriptObject {
    lazy var name: String = self["name"]
    
    lazy var operationType: OperationType = self["operationType"]
    
    lazy var variables: [VariableDefinition] = self["variables"]
    
    lazy var rootType: GraphQLCompositeType = self["rootType"]
    
    lazy var selectionSet: SelectionSet = self["selectionSet"]
    
    lazy var source: String = self["source"]
    
    lazy var filePath: String = self["filePath"]
    
    lazy var operationIdentifier: String = {
      // TODO: Compute this from source + referenced fragments
      fatalError()
    }()

    /// Computes the fragments that the operation uses by all selections on the operation.
    #warning("TODO: Implement this and unit test. Probably want to implement fragments used for each SelectionSet and agregate them here.")
//    public internal(set) lazy var fragmentsUsed: Set<FragmentDefinition> = []
  }
  
  public enum OperationType: String, Equatable, JavaScriptValueDecodable {
    case query
    case mutation
    case subscription
    
    init(_ jsValue: JSValue, bridge: JavaScriptBridge) {
      // No way to use guard when delegating to a failable initializer directly, but since this is a value type
      // we can initialize a local variable instead and assign it to `self` on success.
      // See https://forums.swift.org/t/theres-no-way-to-channel-a-fail-able-initializer-to-a-throwing-one-is-there/19322
      let rawValue: String = .fromJSValue(jsValue, bridge: bridge)
      guard let operationType = Self(rawValue: rawValue) else {
        preconditionFailure("Unknown GraphQL operation type: \(rawValue)")
      }
      
      self = operationType
    }
  }
  
  public class VariableDefinition: JavaScriptObject {
    lazy var name: String = self["name"]
    
    lazy var type: GraphQLType = self["type"]
    
    lazy var defaultValue: GraphQLValue? = self["defaultValue"]
  }
  
  public class FragmentDefinition: JavaScriptObject, Hashable {
    lazy var name: String = self["name"]
    
    lazy var type: GraphQLCompositeType = self["typeCondition"]
    
    lazy var selectionSet: SelectionSet = self["selectionSet"]
    
    lazy var source: String = self["source"]
    
    lazy var filePath: String = self["filePath"]

    public override var debugDescription: String {
      "\(name) on \(type.debugDescription)"
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(name)
    }

    public static func ==(lhs: FragmentDefinition, rhs: FragmentDefinition) -> Bool {
      return lhs.name == rhs.name
    }
  }
  
  public class SelectionSet: JavaScriptWrapper, Hashable {
    lazy var parentType: GraphQLCompositeType = self["parentType"]!
    
    lazy var selections: [Selection] = self["selections"]!

    convenience init(parentType: GraphQLCompositeType, selections: [Selection]) {
      self.init(nil)
      self.parentType = parentType
      self.selections = selections
    }

    /// Returns a `SelectionSet` with the `newSelections` merged in, removing duplicates.
    ///
    /// - Note: If no changes were made the same `SelectionSet` is returned.
    func merging(_ newSelections: [Selection]) -> SelectionSet {
      let selectionsToMerge = newSelections.filter { !selections.contains($0) }

      guard !selectionsToMerge.isEmpty else { return self }

      let copy = self.copy()
      copy.selections += selectionsToMerge
      return copy
    }

    private func copy() -> SelectionSet {
      return SelectionSet(parentType: self.parentType, selections: self.selections)
    }

    public var debugDescription: String {
      let selectionDescriptions = selections.map(\.debugDescription).joined(separator: "\n")
      return """
      SelectionSet on \(parentType) {
        \(indented: selectionDescriptions)
      }
      """
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(parentType)
      hasher.combine(selections)
    }

    public static func ==(lhs: SelectionSet, rhs: SelectionSet) -> Bool {
      return lhs.parentType == rhs.parentType &&
      lhs.selections == rhs.selections
    }
  }
  
  public enum Selection: JavaScriptValueDecodable, CustomDebugStringConvertible, Hashable {
    case field(Field)
    case inlineFragment(InlineFragment)
    case fragmentSpread(FragmentSpread)
    
    init(_ jsValue: JSValue, bridge: JavaScriptBridge) {
      precondition(jsValue.isObject, "Expected JavaScript object but found: \(jsValue)")

      let kind: String = jsValue["kind"].toString()

      switch kind {
      case "Field":
        self = .field(Field(JavaScriptObject(jsValue, bridge: bridge)))
      case "InlineFragment":
        let selectionSet: SelectionSet = bridge.fromJSValue(jsValue["selectionSet"])
        self = .inlineFragment(InlineFragment(selectionSet: selectionSet))
      case "FragmentSpread":
        self = .fragmentSpread(FragmentSpread(jsValue, bridge: bridge))
      default:
        preconditionFailure("""
          Unknown GraphQL selection of kind "\(kind)"
          """)
      }
    }

    public var debugDescription: String {
      switch self {
      case let .field(field):
        return "field - " + field.debugDescription
      case let .inlineFragment(fragment):
        return "fragment " + fragment.debugDescription
      case let .fragmentSpread(fragment):
        return "fragment " + fragment.debugDescription
      }
    }
  }
  
  public class Field: JavaScriptWrapper, Hashable {
    lazy var name: String = self["name"]!
    
    lazy var alias: String? = self["alias"]
    
    var responseKey: String {
      alias ?? name
    }
    
    lazy var arguments: [Argument]? = self["arguments"]
    
    lazy var type: GraphQLType = self["type"]!
    
    lazy var selectionSet: SelectionSet? = self["selectionSet"]
    
    lazy var deprecationReason: String? = self["deprecationReason"]
    
    var isDeprecated: Bool {
      return deprecationReason != nil
    }
    
    lazy var description: String? = self["description"]

    convenience init(
      name: String,
      alias: String? = nil,
      arguments: [Argument]? = nil,
      type: GraphQLType,
      selectionSet: SelectionSet? = nil,
      deprecationReason: String? = nil,
      description: String? = nil
    ) {
      self.init(nil)
      self.name = name
      self.alias = alias
      self.arguments = arguments
      self.type = type
      self.selectionSet = selectionSet
      self.deprecationReason = deprecationReason
      self.description = description
    }

    /// Returns a `Field` with the selections of the `newSelectionSet` merged in,
    /// removing duplicates.
    ///
    /// - Note: If no changes were made the same `Field` is returned.
    func merging(_ newSelectionSet: SelectionSet) -> Field {
      guard let existingSelectionSet = selectionSet else {
        let copy = self.copy()
        copy.selectionSet = newSelectionSet
        return copy
      }

      let mergedSelectionSet = existingSelectionSet.merging(newSelectionSet.selections)
      guard mergedSelectionSet !== existingSelectionSet else { return self }

      let copy = self.copy()
      copy.selectionSet = mergedSelectionSet
      return copy
    }

    private func copy() -> Field {
      return Field(
        name: self.name,
        alias: self.alias,
        arguments: self.arguments,
        type: self.type,
        selectionSet: self.selectionSet,
        deprecationReason: self.deprecationReason,
        description: self.description)
    }

    public var debugDescription: String {
      "\(name): \(type)"
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(name)
      hasher.combine(alias)
      hasher.combine(arguments)
      hasher.combine(type)
      hasher.combine(selectionSet)
    }

    public static func ==(lhs: Field, rhs: Field) -> Bool {
      return lhs.name == rhs.name &&
      lhs.alias == rhs.alias &&
      lhs.arguments == rhs.arguments &&
      lhs.type == rhs.type &&
      lhs.selectionSet == rhs.selectionSet
    }
  }
  
  public class Argument: JavaScriptObject, Hashable {
    lazy var name: String = self["name"]
    
    lazy var value: GraphQLValue = self["value"]

    public func hash(into hasher: inout Hasher) {
      hasher.combine(name)
      hasher.combine(value)
    }

    public static func ==(lhs: Argument, rhs: Argument) -> Bool {
      return lhs.name == rhs.name &&
      lhs.value == rhs.value
    }
  }
  
  public class InlineFragment: Hashable, CustomDebugStringConvertible {
    var parentType: GraphQLCompositeType { self.selectionSet.parentType }
    
    let selectionSet: SelectionSet

    required init(selectionSet: SelectionSet) {      
      self.selectionSet = selectionSet
    }

    public var debugDescription: String {
      "... on \(parentType.debugDescription)"
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(selectionSet)
    }

    public static func ==(lhs: InlineFragment, rhs: InlineFragment) -> Bool {
      return lhs.selectionSet == rhs.selectionSet
    }
  }
  
  public class FragmentSpread: JavaScriptObject, Hashable {
    lazy var fragment: FragmentDefinition = self["fragment"]

    public override var debugDescription: String {
      fragment.debugDescription
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(fragment)
    }

    public static func ==(lhs: FragmentSpread, rhs: FragmentSpread) -> Bool {
      return lhs.fragment == rhs.fragment
    }
  }
}
