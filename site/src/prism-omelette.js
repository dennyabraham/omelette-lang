// Omelette grammar for Prism — mirrors omelette/lexer.lua. Aliased to `egg`.
Prism.languages.omelette = {
  comment: /--.*/,
  string: { pattern: /"(?:\\.|[^"\\])*"/, greedy: true },
  keyword: /\b(?:let|pub|fn|if|then|else|match|with|when|type|and|or|not|lua|to)\b/,
  boolean: /\b(?:true|false|nil)\b/,
  "class-name": /\b[A-Z]\w*/, // capitalized identifier = constructor (Omelette convention)
  number: /\b\d+(?:\.\d+)?\b/,
  operator: /\|>|->|=>|<-|\.\.|==|~=|<=|>=|[-+*/%<>=|:#]/,
  punctuation: /[{}[\]().,]/,
};
Prism.languages.egg = Prism.languages.omelette;
