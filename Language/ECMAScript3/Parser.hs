 -- | Parser for ECMAScript 3.
{-# LANGUAGE FlexibleContexts #-}
module Language.ECMAScript3.Parser
  (parse
  , Parser  
  , expression
  , statement
  , program
  , parseFromString
  , parseFromFile
  -- old and deprecated   
  , parseScriptFromString
  , parseJavaScriptFromFile
  , parseScript
  , parseExpression
  , parseString
  , ParsedStatement
  , ParsedExpression
  , parseSimpleExpr'
  , parseBlockStmt
  , parseStatement
  , StatementParser
  , ExpressionParser
  , assignExpr
  , parseObjectLit  
  ) where

import Language.ECMAScript3.Lexer hiding (identifier)
import qualified Language.ECMAScript3.Lexer as Lexer
import Language.ECMAScript3.Parser.State
import Language.ECMAScript3.Parser.Type
import Language.ECMAScript3.Syntax hiding (pushLabel)
import Language.ECMAScript3.Syntax.Annotations
import Data.Default.Class
import Text.Parsec hiding (parse)
import Text.Parsec.Expr
import Control.Monad(liftM,liftM2)
import Control.Monad.Trans (MonadIO,liftIO)
import Numeric(readDec,readOct,readHex, readFloat)
import Data.Char
import Control.Monad.Identity
import Data.Maybe (isJust, isNothing, fromMaybe)
import Control.Monad.Error
import Control.Applicative ((<$>), (<*>))

{-# DEPRECATED ParsedStatement, ParsedExpression, StatementParser,
               ExpressionParser
    "These type aliases will be hidden in the next version" #-}

{-# DEPRECATED parseSimpleExpr', parseBlockStmt, parseObjectLit
   "These parsers will be hidden in the next version" #-}

{-# DEPRECATED assignExpr, parseExpression "Use 'expression' instead" #-}

{-# DEPRECATED parseStatement "Use 'statement' instead" #-}

{-# DEPRECATED parseScript "Use 'program' instead" #-}

{-# DEPRECATED parseScriptFromString, parseString "Use 'parseFromString' instead" #-}

{-# DEPRECATED parseJavaScriptFromFile "Use 'parseFromFile' instead" #-}

-- We parameterize the parse tree over source-locations.
type ParsedStatement = Statement
type ParsedExpression = Expression

-- These parsers can store some arbitrary state
type StatementParser s = Parser s ParsedStatement
type ExpressionParser s = Parser s ParsedExpression

initialParserState :: ParserState
initialParserState = []

-- | checks if the label is not yet on the stack, if it is -- throws
-- an error; otherwise it pushes it onto the stack
pushLabel :: String -> Parser s ()
pushLabel lab = do labs <- getState
                   if lab `elem` labs 
                     then fail $ "Duplicate label at "
                     else putState (lab:labs)

popLabel :: Parser s ()
popLabel = modifyState safeTail
  where safeTail [] = []
        safeTail (_:xs) = xs

clearLabels :: ParserState -> ParserState
clearLabels _ = []

withFreshLabelStack :: Parser s a -> Parser s a
withFreshLabelStack p = do oldState <- getState
                           putState $ clearLabels oldState
                           a <- p
                           putState oldState
                           return a

identifier :: Stream s Identity Char => Parser s Id
identifier =
  liftM Id Lexer.identifier

--{{{ Statements

-- Keep in mind that Token.reserved parsers (exported from the lexer) do not
-- consume any input on failure.  Note that all statements (expect for labelled
-- and expression statements) begin with a reserved-word.  If we fail to parse
-- this reserved-word, no input is consumed.  Hence, we can have the massive or
-- block that is parseExpression.  Note that if the reserved-word is parsed, it 
-- must be whatever statement the reserved-word indicates.  If we fail after the
-- reserved-word, we truly have a syntax error.  Since input has been consumed,
-- <|> will not try its alternate in parseExpression, and we will fail.

parseIfStmt:: Stream s Identity Char => StatementParser s 
parseIfStmt = do
  reserved "if"
  test <- parseParenExpr <?> "parenthesized test-expression in if statement"
  consequent <- parseStatement <?> "true-branch of if statement"
  optional semi -- TODO: in spec?
  ((do reserved "else"
       alternate <- parseStatement
       return $ IfStmt test consequent alternate)
   <|> return (IfSingleStmt test consequent))

parseSwitchStmt :: Stream s Identity Char => StatementParser s
parseSwitchStmt =
  let parseDefault = do
        reserved "default"
        colon
        statements <- many parseStatement
        return (CaseDefault statements)
      parseCase = do
         reserved "case"
         condition <- parseListExpr
         colon
         actions <- many parseStatement
         return (CaseClause condition actions)
      isCaseDefault (CaseDefault _) = True   
      isCaseDefault _                 = False
      checkClauses cs = case filter isCaseDefault cs of
        (_:c:_) -> fail $ "duplicate default clause in switch statement at "
        _ -> return ()                  
    in do reserved "switch"
          test <- parseParenExpr
          clauses <- braces $ many $ parseDefault <|> parseCase
          checkClauses clauses
          return (SwitchStmt test clauses)

parseWhileStmt:: Stream s Identity Char => StatementParser s
parseWhileStmt = do
  reserved "while"
  test <- parseParenExpr <?> "parenthesized test-expression in while loop"
  body <- parseStatement
  return (WhileStmt test body)

parseDoWhileStmt:: Stream s Identity Char => StatementParser s
parseDoWhileStmt = do
  reserved "do"
  body <- parseStatement
  reserved "while" <?> "while at the end of a do block"
  test <- parseParenExpr <?> "parenthesized test-expression in do loop"
  optional semi
  return (DoWhileStmt body test)

parseContinueStmt:: Stream s Identity Char => StatementParser s
parseContinueStmt = do
  pos <- getPosition
  reserved "continue"
  pos' <- getPosition
  -- Ensure that the identifier is on the same line as 'continue.'
  id <- if sourceLine pos == sourceLine pos'
        then liftM Just identifier <|> return Nothing
        else return Nothing
  optional semi
  return $ ContinueStmt id

parseBreakStmt:: Stream s Identity Char => StatementParser s
parseBreakStmt = do
  pos <- getPosition
  reserved "break"
  pos' <- getPosition
  -- Ensure that the identifier is on the same line as 'break.'
  id <- if sourceLine pos == sourceLine pos'
        then liftM Just identifier <|> return Nothing
        else return Nothing
  optional semi           
  return $ BreakStmt id

parseBlockStmt:: Stream s Identity Char => StatementParser s
parseBlockStmt = do
  statements <- braces (many parseStatement)
  return (BlockStmt statements)

parseEmptyStmt:: Stream s Identity Char => StatementParser s
parseEmptyStmt = do
  semi
  return (EmptyStmt)

parseLabelledStmt:: Stream s Identity Char => StatementParser s
parseLabelledStmt = do
  pos <- getPosition
  -- Lookahead for the colon.  If we don't see it, we are parsing an identifier
  -- for an expression statement.
  label <- try (do label <- identifier
                   colon
                   return label)
  pushLabel $ unId label
  statement <- parseStatement
  popLabel
  return (LabelledStmt label statement)

parseExpressionStmt:: Stream s Identity Char => StatementParser s
parseExpressionStmt = do
  pos <- getPosition
  expr <- parseExpression -- TODO: spec 12.4?
  optional semi
  return $ ExprStmt expr


parseForInStmt:: Stream s Identity Char => StatementParser s
parseForInStmt =
  let parseInit = (reserved "var" >> liftM ForInVar identifier)
               <|> liftM ForInLVal lvalue
  in do pos <- getPosition
        -- Lookahead, so that we don't clash with parseForStmt
        (init,expr) <- try $ do reserved "for"
                                parens $ do init <- parseInit
                                            reserved "in"
                                            expr <- parseExpression
                                            return (init,expr)
        body <- parseStatement
        return $ ForInStmt init expr body

parseForStmt:: Stream s Identity Char => StatementParser s
parseForStmt =
  let parseInit = (reserved "var" >> liftM VarInit (parseVarDecl `sepBy` comma))
               <|> liftM ExprInit parseListExpr
               <|> return NoInit
    in do pos <- getPosition
          reserved "for"
          reservedOp "("
          init <- parseInit
          semi
          test <- optionMaybe parseExpression
          semi
          iter <- optionMaybe parseExpression
          reservedOp ")" <?> "closing paren"
          stmt <- parseStatement
          return $ ForStmt init test iter stmt

parseTryStmt:: Stream s Identity Char => StatementParser s
parseTryStmt =
  let parseCatchClause = do pos <- getPosition
                            reserved "catch"
                            id <- parens identifier
                            stmt <- parseStatement
                            return $ CatchClause id stmt
  in do reserved "try"
        pos <- getPosition
        guarded <- parseStatement
        mCatch <- optionMaybe parseCatchClause
        mFinally <- optionMaybe $ reserved "finally" >> parseStatement
        -- the spec requires at least a catch or a finally block to
        -- be present
        if isJust mCatch || isJust mFinally 
          then return $ TryStmt guarded mCatch mFinally
          else fail $ "A try statement should have at least a catch\ 
                      \ or a finally block, at " ++ show pos

parseThrowStmt:: Stream s Identity Char => StatementParser s
parseThrowStmt = do
  pos <- getPosition
  reserved "throw"
  expr <- parseExpression
  optional semi
  return (ThrowStmt expr)

parseReturnStmt:: Stream s Identity Char => StatementParser s
parseReturnStmt = do
  pos <- getPosition
  reserved "return"
  expr <- optionMaybe parseListExpr
  optional semi
  return (ReturnStmt expr)

parseWithStmt:: Stream s Identity Char => StatementParser s
parseWithStmt = do
  pos <- getPosition
  reserved "with"
  context <- parseParenExpr
  stmt <- parseStatement
  return (WithStmt context stmt)

parseVarDecl :: Stream s Identity Char => Parser s VarDecl
parseVarDecl = do
  pos <- getPosition
  id <- identifier
  init <- (reservedOp "=" >> liftM Just assignExpr) <|> return Nothing
  return (VarDecl id init)

parseVarDeclStmt:: Stream s Identity Char => StatementParser s
parseVarDeclStmt = do 
  pos <- getPosition
  reserved "var"
  decls <- parseVarDecl `sepBy` comma
  optional semi
  return (VarDeclStmt decls)

parseFunctionStmt:: Stream s Identity Char => StatementParser s
parseFunctionStmt = do
  pos <- getPosition
  name <- try (reserved "function" >> identifier) -- ambiguity with FuncExpr
  args <- parens (identifier `sepBy` comma)
  -- label sets don't cross function boundaries
  BlockStmt body <- withFreshLabelStack parseBlockStmt <?> 
                      "function body in { ... }"
  return (FunctionStmt name args body)

parseStatement :: Stream s Identity Char => StatementParser s
parseStatement = parseIfStmt <|> parseSwitchStmt <|> parseWhileStmt 
  <|> parseDoWhileStmt <|> parseContinueStmt <|> parseBreakStmt 
  <|> parseBlockStmt <|> parseEmptyStmt <|> parseForInStmt <|> parseForStmt
  <|> parseTryStmt <|> parseThrowStmt <|> parseReturnStmt <|> parseWithStmt 
  <|> parseVarDeclStmt  <|> parseFunctionStmt
  -- labelled, expression and the error message always go last, in this order
  <|> parseLabelledStmt <|> parseExpressionStmt <?> "statement"

-- | The parser that parses a single ECMAScript statement
statement :: Stream s Identity Char => Parser s Statement
statement = parseStatement

--}}}

--{{{ Expressions

-- References used to construct this stuff:
-- + http://developer.mozilla.org/en/docs/
--     Core_JavaScript_1.5_Reference:Operators:Operator_Precedence
-- + http://www.mozilla.org/js/language/grammar14.html
--
-- Aren't expression tables nice?  Well, we can't quite use them, because of 
-- JavaScript's ternary (?:) operator.  We have to use two expression tables.
-- We use one expression table for the assignment operators that bind looser 
-- than ?: (assignTable).  The terms of assignTable are ternary expressions 
-- (parseTernaryExpr).  parseTernaryExpr left-factors the left-recursive
-- production for ?:, and is defined over the second expression table, 
-- exprTable, which consists of operators that bind tighter than ?:.  The terms
-- of exprTable are atomic expressions, parenthesized expressions, functions and
-- array references.

--{{{ Primary expressions

parseThisRef:: Stream s Identity Char => ExpressionParser s
parseThisRef = do
  pos <- getPosition
  reserved "this"
  return (ThisRef)

parseNullLit:: Stream s Identity Char => ExpressionParser s
parseNullLit = do
  pos <- getPosition
  reserved "null"
  return (NullLit)


parseBoolLit:: Stream s Identity Char => ExpressionParser s
parseBoolLit = do
    pos <- getPosition
    let parseTrueLit  = reserved "true"  >> return (BoolLit True)
        parseFalseLit = reserved "false" >> return (BoolLit False)
    parseTrueLit <|> parseFalseLit

parseVarRef:: Stream s Identity Char => ExpressionParser s
parseVarRef = liftM VarRef identifier

parseArrayLit:: Stream s Identity Char => ExpressionParser s
parseArrayLit = liftM ArrayLit (squares (assignExpr `sepEndBy` comma))

parseFuncExpr :: Stream s Identity Char => ExpressionParser s
parseFuncExpr = do
  pos <- getPosition
  reserved "function"
  name <- optionMaybe identifier
  args <- parens (identifier `sepBy` comma)
  -- labels don't cross function boundaries
  BlockStmt body <- withFreshLabelStack parseBlockStmt
  return $ FuncExpr name args body

--{{{ parsing strings

escapeChars =
 [('\'','\''),('\"','\"'),('\\','\\'),('b','\b'),('f','\f'),('n','\n'),
  ('r','\r'),('t','\t'),('v','\v'),('/','/'),(' ',' '),('0','\0')]

allEscapes:: String
allEscapes = map fst escapeChars

parseEscapeChar :: Stream s Identity Char => Parser s Char
parseEscapeChar = do
  c <- oneOf allEscapes
  let (Just c') = lookup c escapeChars -- will succeed due to line above
  return c' 

parseAsciiHexChar :: Stream s Identity Char => Parser s Char
parseAsciiHexChar = do
  char 'x'
  d1 <- hexDigit
  d2 <- hexDigit
  return ((chr.fst.head.readHex) (d1:d2:""))

parseUnicodeHexChar :: Stream s Identity Char => Parser s Char
parseUnicodeHexChar = do
  char 'u'
  liftM (chr.fst.head.readHex) 
        (sequence [hexDigit,hexDigit,hexDigit,hexDigit])
        
isWhitespace ch = ch `elem` " \t"


-- The endWith argument is either single-quote or double-quote, depending on how
-- we opened the string.
parseStringLit' endWith =
  (char endWith >> return "") <|>
  (do try (string "\\'")
      cs <- parseStringLit' endWith
      return $ "'" ++ cs) <|>
  (do char '\\'
      c <- parseEscapeChar <|> parseAsciiHexChar <|> parseUnicodeHexChar <|> 
           char '\r' <|> char '\n'
      cs <- parseStringLit' endWith
      if c == '\r' || c == '\n' 
        then return (c:dropWhile isWhitespace cs) 
        else return (c:cs)) <|>
   liftM2 (:) anyChar (parseStringLit' endWith)

parseStringLit:: Stream s Identity Char => ExpressionParser s
parseStringLit = do
  pos <- getPosition
  -- parseStringLit' takes as an argument the quote-character that opened the
  -- string.
  str <- lexeme $ (char '\'' >>= parseStringLit') <|> (char '\"' >>= parseStringLit')
  -- CRUCIAL: Parsec.Token parsers expect to find their token on the first
  -- character, and read whitespaces beyond their tokens.  Without 'lexeme'
  -- above, expressions like:
  --   var s = "string"   ;
  -- do not parse.
  return $ StringLit str

--}}}

parseRegexpLit:: Stream s Identity Char => ExpressionParser s
parseRegexpLit = do
  let parseFlags = do
        flags <- many (oneOf "mgi")
        return $ \f -> f ('g' `elem` flags) ('i' `elem` flags) 
  let parseEscape :: Stream s Identity Char => Parser s Char
      parseEscape = char '\\' >> anyChar
  let parseChar :: Stream s Identity Char => Parser s Char
      parseChar = noneOf "/"
  let parseRe = (char '/' >> return "") <|> 
                (do char '\\'
                    ch <- anyChar -- TODO: too lenient
                    rest <- parseRe
                    return ('\\':ch:rest)) <|> 
                liftM2 (:) anyChar parseRe
  pos <- getPosition
  char '/'
  notFollowedBy $ char '/'
  pat <- parseRe --many1 parseChar
  flags <- parseFlags
  spaces -- crucial for Parsec.Token parsers
  return $ flags (RegexpLit pat)
          
parseObjectLit:: Stream s Identity Char => ExpressionParser s
parseObjectLit =
  let parseProp = do
        -- Parses a string, identifier or integer as the property name.  I
        -- apologize for the abstruse style, but it really does make the code
        -- much shorter.
        name <- liftM (\(StringLit s) -> PropString s) parseStringLit
            <|> liftM PropId identifier
            <|> liftM PropNum (parseNumber >>= toInt)
        colon
        val <- assignExpr
        return (name,val)
      toInt eid = case eid of
        Left i -> return $ fromIntegral i
        -- Note, the spec actually allows floats in property names.
        -- This is left for legacy reasons and will be fixed in 1.0
        Right d-> unexpected "Floating point number in property name"
    in do pos <- getPosition
          props <- braces (parseProp `sepEndBy` comma) <?> "object literal"
          return $ ObjectLit props

--{{{ Parsing numbers.  From pg. 17-18 of ECMA-262.
hex :: Stream s Identity Char => Parser s (Either Int Double)
hex = do s <- hexIntLit
         Left <$> wrapReadS Numeric.readHex s

decimal :: Stream s Identity Char => Parser s (Either Int Double)
decimal = do (s, i) <- decLit
             if i then Left <$> wrapReadS readDec s
                  else Right <$> wrapReadS readFloat s

wrapReadS :: ReadS a -> String -> Parser s a
wrapReadS r s = case r s of
  [(a, "")] -> return a
  _         -> fail "Bad parse: could not convert a string to a Haskell value"

parseNumber:: Stream s Identity Char => Parser s (Either Int Double) 
parseNumber = hex <|> decimal

parseNumLit:: Stream s Identity Char => ExpressionParser s
parseNumLit = do pos <- getPosition
                 eid <- lexeme $ parseNumber
                 notFollowedBy identifierStart <?> "whitespace"
                 return $ case eid of
                   Left i -> IntLit i
                   Right d-> NumLit d

------------------------------------------------------------------------------
-- Position Helper
------------------------------------------------------------------------------

withPos cstr p = do { pos <- getPosition; e <- p; return $ cstr pos e }

-------------------------------------------------------------------------------
-- Compound Expression Parsers
-------------------------------------------------------------------------------

dotRef e = (reservedOp "." >> withPos cstr identifier) <?> "property.ref"
    where cstr pos = DotRef e

funcApp e = parens (withPos cstr (assignExpr `sepBy` comma)) 
         <?>"(function application)"
    where cstr pos = CallExpr e

bracketRef e = brackets (withPos cstr parseExpression) <?> "[property-ref]"
    where cstr pos = BracketRef e

-------------------------------------------------------------------------------
-- Expression Parsers
-------------------------------------------------------------------------------

parseParenExpr:: Stream s Identity Char => ExpressionParser s
parseParenExpr = parens parseListExpr

-- everything above expect functions
parseExprForNew :: Stream s Identity Char => ExpressionParser s
parseExprForNew = parseThisRef <|> parseNullLit <|> parseBoolLit <|> parseStringLit 
  <|> parseArrayLit <|> parseParenExpr <|> parseNewExpr <|> parseNumLit 
  <|> parseRegexpLit <|> parseObjectLit <|> parseVarRef

-- all the expression parsers defined above
parseSimpleExpr' :: Stream s Identity Char => ExpressionParser s
parseSimpleExpr' = parseThisRef <|> parseNullLit <|> parseBoolLit 
  <|> parseStringLit <|> parseArrayLit <|> parseParenExpr
  <|> parseFuncExpr <|> parseNumLit <|> parseRegexpLit <|> parseObjectLit
  <|> parseVarRef

parseNewExpr :: Stream s Identity Char => ExpressionParser s
parseNewExpr =
  (do pos <- getPosition
      reserved "new"
      constructor <- parseSimpleExprForNew Nothing -- right-associativity
      arguments <- try (parens (assignExpr `sepBy` comma)) <|> return []
      return (NewExpr constructor arguments)) <|>
  parseSimpleExpr'

parseSimpleExpr (Just e) = ((dotRef e <|> funcApp e <|> bracketRef e) >>=
                            parseSimpleExpr . Just)  
                        <|> return e
parseSimpleExpr Nothing = do
  e <- parseNewExpr <?> "expression (3)"
  parseSimpleExpr (Just e)

parseSimpleExprForNew :: Stream s Identity Char
                      =>(Maybe ParsedExpression) -> ExpressionParser s
parseSimpleExprForNew (Just e) = ((dotRef e <|> bracketRef e) >>=
                                  parseSimpleExprForNew . Just)
                              <|> return e
parseSimpleExprForNew Nothing = do
  e <- parseNewExpr <?> "expression (3)"
  parseSimpleExprForNew (Just e)
    
--}}}

makeInfixExpr str constr = Infix parser AssocLeft where
  parser:: Stream s Identity Char
        => Parser s (Expression -> Expression -> Expression)
  parser = do
    pos <- getPosition
    reservedOp str
    return (InfixExpr constr)  -- points-free, returns a function


-- apparently, expression tables can't handle immediately-nested prefixes
parsePrefixedExpr :: Stream s Identity Char => ExpressionParser s
parsePrefixedExpr = do
  pos <- getPosition
  op <- optionMaybe $ (reservedOp "!" >> return PrefixLNot) <|> 
                      (reservedOp "~" >> return PrefixBNot) <|>
                      (try (lexeme $ char '-' >> notFollowedBy (char '-')) >>
                       return PrefixMinus) <|>
                      (try (lexeme $ char '+' >> notFollowedBy (char '+')) >>
                       return PrefixPlus) <|>
                      (reserved "typeof" >> return PrefixTypeof) <|>
                      (reserved "void" >> return PrefixVoid) <|>
                      (reserved "delete" >> return PrefixDelete)
  case op of
    Nothing -> unaryAssignExpr
    Just op -> do
      innerExpr <- parsePrefixedExpr
      return (PrefixExpr op innerExpr)

exprTable:: Stream s Identity Char => [[Operator s ParserState Identity ParsedExpression]]
exprTable = 
  [ [ makeInfixExpr "*" OpMul
    , makeInfixExpr "/" OpDiv
    , makeInfixExpr "%" OpMod
    ]
  , [ makeInfixExpr "+" OpAdd
    , makeInfixExpr "-" OpSub
    ]
  , [ makeInfixExpr "<<" OpLShift
    , makeInfixExpr ">>" OpSpRShift
    , makeInfixExpr ">>>" OpZfRShift
    ]
  , [ makeInfixExpr "<" OpLT
    , makeInfixExpr "<=" OpLEq
    , makeInfixExpr ">" OpGT
    , makeInfixExpr ">=" OpGEq
    , makeInfixExpr "instanceof" OpInstanceof
    , makeInfixExpr "in" OpIn
    ]
  , [ makeInfixExpr "==" OpEq
    , makeInfixExpr "!=" OpNEq
    , makeInfixExpr "===" OpStrictEq
    , makeInfixExpr "!==" OpStrictNEq
    ]
  , [ makeInfixExpr "&" OpBAnd ]
  , [ makeInfixExpr "^" OpBXor ]
  , [ makeInfixExpr "|" OpBOr ]
  , [ makeInfixExpr "&&" OpLAnd ]
  , [ makeInfixExpr "||" OpLOr ]
  ]

parseExpression' :: Stream s Identity Char => ExpressionParser s
parseExpression' = 
  buildExpressionParser exprTable parsePrefixedExpr <?> "simple expression"

asLValue :: Stream s Identity Char
         => Expression
         -> Parser s LValue
asLValue e = case e of
  VarRef (Id x) -> return (LVar x)
  DotRef e (Id x) -> return (LDot e x)
  BracketRef e1 e2 -> return (LBracket e1 e2)
  otherwise -> fail $ "expected a left-value at "

lvalue :: Stream s Identity Char => Parser s LValue
lvalue = do
  p <- getPosition
  e <- parseSimpleExpr Nothing
  asLValue e

unaryAssignExpr :: Stream s Identity Char => ExpressionParser s
unaryAssignExpr = do
  p <- getPosition
  let prefixInc = do
        reservedOp "++"
        liftM (UnaryAssignExpr PrefixInc) lvalue
  let prefixDec = do
        reservedOp "--"
        liftM (UnaryAssignExpr PrefixDec) lvalue
  let postfixInc e = do
        reservedOp "++"
        liftM (UnaryAssignExpr PostfixInc) (asLValue e)
  let postfixDec e = do
        reservedOp "--"
        liftM (UnaryAssignExpr PostfixDec) (asLValue e)
  let other = do
        e <- parseSimpleExpr Nothing
        postfixInc e <|> postfixDec e <|> return e
  prefixInc <|> prefixDec <|> other

parseTernaryExpr':: Stream s Identity Char
                 => Parser s (ParsedExpression,ParsedExpression)
parseTernaryExpr' = do
    reservedOp "?"
    l <- assignExpr
    colon
    r <- assignExpr
    return (l,r)

parseTernaryExpr:: Stream s Identity Char => ExpressionParser s
parseTernaryExpr = do
  e <- parseExpression'
  e' <- optionMaybe parseTernaryExpr'
  case e' of
    Nothing -> return e
    Just (l,r) -> do p <- getPosition
                     return $ CondExpr e l r

assignOp :: Stream s Identity Char => Parser s AssignOp
assignOp = (reservedOp "=" >> return OpAssign)
        <|>(reservedOp "+=" >> return OpAssignAdd)
        <|>(reservedOp "-=" >> return OpAssignSub)
        <|>(reservedOp "*=" >> return OpAssignMul)
        <|>(reservedOp "/=" >> return OpAssignDiv)
        <|>(reservedOp "%=" >> return OpAssignMod)
        <|>(reservedOp "<<=" >> return OpAssignLShift)
        <|>(reservedOp ">>=" >> return OpAssignSpRShift)
        <|>(reservedOp ">>>=" >> return OpAssignZfRShift)
        <|>(reservedOp "&=" >> return OpAssignBAnd)
        <|>(reservedOp "^=" >> return OpAssignBXor)
        <|>(reservedOp "|=" >> return OpAssignBOr)

assignExpr :: Stream s Identity Char => ExpressionParser s
assignExpr = do
  p <- getPosition
  lhs <- parseTernaryExpr
  let assign = do
        op <- assignOp
        lhs <- asLValue lhs
        rhs <- assignExpr
        return (AssignExpr op lhs rhs)
  assign <|> return lhs

parseExpression:: Stream s Identity Char => ExpressionParser s
parseExpression = parseListExpr

-- | A parser that parses ECMAScript expressions
expression :: Stream s Identity Char => Parser s Expression
expression = parseExpression

parseListExpr :: Stream s Identity Char => ExpressionParser s
parseListExpr = assignExpr `sepBy1` comma >>= \exprs ->
  case exprs of
    [expr] -> return expr
    es     -> liftM ListExpr (return es)

parseScript:: Stream s Identity Char => Parser s JavaScript
parseScript = do
  whiteSpace
  liftM Script (parseStatement `sepBy` whiteSpace)

-- | A parser that parses an ECMAScript program.
program :: Stream s Identity Char => Parser s JavaScript
program = parseScript
  
-- | Parse from a stream given a parser, same as 'Text.Parsec.parse'
-- in Parsec. We can use this to parse expressions or statements alone,
-- not just whole programs.
parse :: Stream s Identity Char
      => Parser s a -- ^ The parser to use
      -> SourceName -- ^ Name of the source file
      -> s -- ^ the stream to parse, usually a 'String'
      -> Either ParseError a
parse p = runParser p initialParserState

-- | A convenience function that takes a 'String' and tries to parse
-- it as an ECMAScript program:
--
-- > parseFromString = parse program ""
parseFromString :: String -- ^ JavaScript source to parse
                  -> Either ParseError JavaScript
parseFromString = parse program ""

-- | A convenience function that takes a filename and tries to parse
-- the file contents an ECMAScript program, it fails with an error
-- message if it can't.
parseFromFile :: (Error e, MonadIO m, MonadError e m) => String -- ^ file name
                -> m JavaScript
parseFromFile fname =
  liftIO (readFile fname) >>= \source ->
  case parse program fname source of
    Left err -> throwError $ strMsg $ show err
    Right js -> return js

-- | Read a JavaScript program from file an parse it into a list of
-- statements
parseJavaScriptFromFile :: MonadIO m => String -- ^ file name
                        -> m [Statement]
parseJavaScriptFromFile filename = do
  chars <- liftIO $ readFile filename
  case parse parseScript filename chars of
    Left err               -> fail (show err)
    Right (Script stmts) -> return stmts

-- | Parse a JavaScript program from a string
parseScriptFromString :: String -- ^ source file name
                      -> String -- ^ JavaScript source to parse
                      -> Either ParseError JavaScript
parseScriptFromString = parse parseScript

-- | Parse a JavaScript source string into a list of statements
parseString :: String -- ^ JavaScript source
            -> [Statement]
parseString str = case parse parseScript "" str of
  Left err -> error (show err)
  Right (Script stmts) -> stmts
