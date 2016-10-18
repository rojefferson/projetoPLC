module Value (Value (..)) where
	
import Language.ECMAScript3.Syntax

data Value = Bool Bool
    | Int Int
    | String String
    | Var String
	| Break
	| Continue
	| Function [Id] [Statement]
	| List [Value]
	| Return (Maybe Value)
    | Nil

--
-- Pretty Printer
--

instance Eq Value where
	(Int v1) == (Int v2) = v1 == v2
	(Bool v1) == (Bool v2) = v1 == v2
	(List l1) == (List l2) = l1 == l2
	Continue == Continue = True
	Break == Break = True
	Continue == _ = False
	Break == _ = False
	_ == Continue = False	
	_ == Break = False

instance Show Value where 
  show (Bool True) = "true"
  show (Bool False) = "false"
  show (Int int) = show int
  show (String str) = "\"" ++ str ++ "\""
  show (Var name) = name
  show Break = "break"
  show Nil = "undefined"
  show (List l) = show l
  show (Function _ _) = "Function"
  
-- This function could be replaced by (unwords.map show). The unwords
-- function takes a list of String values and uses them to build a 
-- single String where the words are separated by spaces.
showListContents :: [Value] -> String
showListContents [] = ""
showListContents [a] = show a
showListContents (a:as) = show a ++ ", " ++ (showListContents as)
