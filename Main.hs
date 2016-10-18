import qualified Language.ECMAScript3.Parser as Parser
import Language.ECMAScript3.Syntax
import Control.Monad
import Control.Applicative
import Data.Map as Map (Map, insert, lookup, union, toList, empty)
import Debug.Trace
import Value

--
-- Evaluate functions
--

evalExpr :: StateT -> Expression -> StateTransformer Value
evalExpr env (VarRef (Id id)) = stateLookup env id
evalExpr env (IntLit int) = return $ Int int
evalExpr env (BoolLit bool) = return $ Bool bool
evalExpr env (StringLit str) = return $ String str
evalExpr env (ArrayLit []) = return (List [])
evalExpr env (ArrayLit (x:xs)) = do
    inicio <- evalExpr env x
    (List resto) <- evalExpr env (ArrayLit xs)
    return (List (inicio:resto))
evalExpr env (UnaryAssignExpr unOp (LVar lVal)) = do
	case unOp of 
		(PrefixInc) -> evalExpr env (AssignExpr OpAssign (LVar lVal) (InfixExpr OpAdd (VarRef (Id lVal)) (IntLit 1)))
		(PrefixDec) -> evalExpr env (AssignExpr OpAssign (LVar lVal) (InfixExpr OpSub (VarRef (Id lVal)) (IntLit 1)))
		(PostfixInc) -> do 
						(Int v) <- evalExpr env (VarRef (Id lVal))
						write lVal (Int (v + 1))
						return (Int v)
		(PostfixDec) -> do 
						(Int v) <- evalExpr env (VarRef (Id lVal))
						write lVal (Int (v - 1))
						return (Int v)
evalExpr env (InfixExpr op expr1 expr2) = do
    v1 <- evalExpr env expr1
    v2 <- evalExpr env expr2
    infixOp env op v1 v2
evalExpr env (BracketRef name index) = do
    (List v) <- evalExpr env name
    (Int i) <- evalExpr env index
    return $ v !! i
evalExpr env (DotRef  exp (Id id)) = do
    (List l) <- evalExpr env exp
    case id of
        "len" -> return (Int (length l))
        "head" -> return (head l)
        "tail" -> return (List (tail l))      
        
evalExpr env (AssignExpr OpAssignAdd (LVar var) expr) = do
	(Int v1) <- evalExpr env (VarRef (Id var))
	(Int v2) <- evalExpr env expr
	evalExpr env (AssignExpr OpAssign (LVar var) (IntLit (v1 + v2)))
	
evalExpr env (AssignExpr OpAssignSub (LVar var) expr) = do
	(Int v1) <- evalExpr env (VarRef (Id var))
	(Int v2) <- evalExpr env expr
	evalExpr env (AssignExpr OpAssign (LVar var) (IntLit (v1 - v2)))
	
  
evalExpr env (AssignExpr OpAssign var expr) = do
	case var of
	    (LVar str) -> do
	        stateLookup env str -- crashes if the variable doesn't exist
	        e <- evalExpr env expr
	        write str e
	    (LBracket (VarRef (Id name)) index) -> do
	        (List l) <- stateLookup env name
	        (Int i) <- evalExpr env index
	        v <- evalExpr env expr
	        write name (List (update l i v))
evalExpr env (ListExpr []) = return Nil
evalExpr env (ListExpr (x:xs)) = evalExpr env x >> evalExpr env (ListExpr xs)
evalExpr env (FuncExpr (Just (Id name)) param commands) = do
	push name (Function param commands)

evalExpr env (CallExpr (DotRef exp (Id name)) params) = do
	(List obj) <- evalExpr env exp
	case name of
		"len" -> return (Int (length obj))
		"head" -> return (head obj)
		"tail" -> return (List (tail obj))
		"concat" -> do
			(List l) <- evalExpr env (params !! 0)
			return (List (obj ++ l))
		"add" -> do
			val <- evalExpr env (params !! 0)
			return (List (obj ++ [val]))
		
evalExpr env (CallExpr name params) = do
	(Int h) <- height
	(Function names commands) <- evalExpr env name
	evalStmt env (VarDeclStmt (map (\(l,r) -> (VarDecl l (Just r))) (zip names params)))
	r <- evalStmt env (BlockStmt commands)
	popLength h
	case r of 
		(Return (Just val)) -> return val
		_ -> return Nil
		
update [] i v = []
update (x:xs) i v = if i == 0 then (v:xs) else (x:update xs (i -1) v)

evalStmt :: StateT -> Statement -> StateTransformer Value
evalStmt env EmptyStmt = return Nil
evalStmt env (VarDeclStmt []) = return Nil
evalStmt env (VarDeclStmt (decl:ds)) =
    varDecl env decl >> evalStmt env (VarDeclStmt ds)
evalStmt env (ExprStmt expr) = evalExpr env expr
evalStmt env (BlockStmt []) = return Nil
evalStmt env (BlockStmt (x:xs)) = do 
	v1 <- evalStmt env x
	case v1 of 
		Break -> return Break
		Continue -> return Continue
		(Return val) -> return (Return val)
		_ -> evalStmt env (BlockStmt xs)
		
evalStmt env (IfSingleStmt cond command) = do
	(Int h) <- height 
	v1 <- evalExpr env cond
	if v1 == (Bool True) then do
		r <- evalStmt env command
		popLength h
		return r
	else return Nil
	
evalStmt env (IfStmt cond command1 command2) = do
	(Int h) <- height
	v1 <- evalExpr env cond
	if v1 == (Bool True) then do
		evalStmt env command1
		popLength h
	else if v1 == (Bool False) then do
		evalStmt env command2
		popLength h
	else return Nil

evalStmt env (SwitchStmt command []) = return Nil
evalStmt env (SwitchStmt command (c:cs)) = case c of 
 	(CaseClause command1 stmt) -> do
		(Int h) <- height
	 	v1 <- evalExpr env command
	 	v2 <- evalExpr env command1
	 	if v1 == v2 then do
		 	evalStmt env (BlockStmt stmt)
			popLength h
	 	else do
			(Int h) <- height
		 	evalStmt env (SwitchStmt command cs)
			popLength h
 	(CaseDefault stmt1) -> do
		(Int h) <- height
		evalStmt env (BlockStmt stmt1)	
		popLength h
		
		
evalStmt env (ForStmt NoInit (Just test) inc stmts) = do
	(Int h) <- height
	t <- evalExpr env test
	if t == (Bool True) then do
		r <- evalStmt env stmts
		case r of
			Break -> popLength h
			(Return r) -> do 
				popLength h
				return (Return r)
			_ -> case inc of
					Nothing -> do
						evalStmt env (ForStmt NoInit (Just test) Nothing stmts)
						popLength h
					(Just i) -> do
						evalExpr env i
						evalStmt env (ForStmt NoInit (Just test) (Just i) stmts)
						popLength h
	else
		popLength h
		
evalStmt env (ForStmt (VarInit decls) (Just test) inc stmts) = do
	(Int h) <- height
	evalStmt env (VarDeclStmt decls)
	t <- evalExpr env test
	if t == (Bool True) then do
		r <- evalStmt env stmts
		case r of
			Break -> popLength h
			(Return r) -> do 
				popLength h
				return (Return r)
			_ -> case inc of
					Nothing -> do
						evalStmt env (ForStmt NoInit (Just test) Nothing stmts)
						popLength h
					(Just i) -> do
						evalExpr env i
						evalStmt env (ForStmt NoInit (Just test) (Just i) stmts)
						popLength h
	else
		popLength h

evalStmt env (ForStmt NoInit Nothing inc stmts) = do
	(Int h) <- height
	r <- evalStmt env stmts
	case r of
		Break -> popLength h
		(Return r) -> do 
			popLength h
			return (Return r)
		_ -> case inc of
				Nothing -> do
					evalStmt env (ForStmt NoInit Nothing Nothing stmts)
					popLength h
				(Just i) -> do
					evalExpr env i
					evalStmt env (ForStmt NoInit Nothing (Just i) stmts)
					popLength h	
			
evalStmt env (ForStmt (VarInit decls) Nothing inc stmts) = do
	(Int h) <- height
	evalStmt env (VarDeclStmt decls)
	r <- evalStmt env stmts
	case r of
		Break -> popLength h
		(Return r) -> do 
			popLength h
			return (Return r)
		_ -> case inc of
				Nothing -> do
					evalStmt env (ForStmt NoInit Nothing Nothing stmts)
					popLength h
				(Just i) -> do
					evalExpr env i
					evalStmt env (ForStmt NoInit Nothing (Just i) stmts)
					popLength h
					
					
--data ForInInit = ForInVar Id -- ^ @var x@
--                 | ForInLVal LValue -					
evalStmt env (ForInStmt (ForInVar (Id id)) list commands) = do
	(Int h) <- height
	(List (l:ls)) <- evalExpr env list
	push id l
	evalStmt env commands
	popLength h
	evalStmt env (ForInStmt (ForInVar (Id id)) (BracketRef list (IntLit 1)) commands)
	
evalStmt env (ForInStmt (ForInVar (Id id)) (BracketRef list (IntLit i)) commands) = do
	(Int h) <- height
	(List l) <- evalExpr env list
	if length l == i then
		popLength h
	else do
		push id (l !! i)
		evalStmt env commands
		popLength h
		evalStmt env (ForInStmt (ForInVar (Id id)) (BracketRef list (IntLit (i+1))) commands)

evalStmt env (WhileStmt cond command) = do
	(Int h) <- height
	v1 <- evalExpr env cond
	if v1 == (Bool True) then
		do
			v2 <- evalStmt env command
			popLength h
			case v2 of
				Break -> return Nil
				(Return r) -> return (Return r)
				_ -> evalStmt env (WhileStmt cond command)
	else 
		return Nil
evalStmt env (DoWhileStmt command cond) = do
	v1 <- evalStmt env command
	case v1 of 
		Break -> return Nil
		(Return r) -> return (Return r)
		_ -> do
			v2 <- evalExpr env cond
			if v2 == (Bool True) then
				evalStmt env (DoWhileStmt command cond)
			else 
				return Nil
evalStmt env (BreakStmt id) = return Break
evalStmt env (ContinueStmt id) = return Continue
evalStmt env (ReturnStmt val) = do
	case val of 
		Nothing -> return (Return Nothing)
		(Just exp) -> do 
			val <- evalExpr env exp
			return (Return (Just val))
evalStmt env (FunctionStmt name params stmts) = evalExpr env (FuncExpr (Just name) params stmts)

-- Do not touch this one :)
evaluate :: StateT -> [Statement] -> StateTransformer Value
evaluate env [] = return Nil
evaluate env stmts = foldl1 (>>) $ map (evalStmt env) stmts

--
-- Operators
--

infixOp :: StateT -> InfixOp -> Value -> Value -> StateTransformer Value
infixOp env OpAdd  (Int  v1) (Int  v2) = return $ Int  $ v1 + v2
infixOp env OpSub  (Int  v1) (Int  v2) = return $ Int  $ v1 - v2
infixOp env OpMul  (Int  v1) (Int  v2) = return $ Int  $ v1 * v2
infixOp env OpDiv  (Int  v1) (Int  v2) = return $ Int  $ div v1 v2
infixOp env OpMod  (Int  v1) (Int  v2) = return $ Int  $ mod v1 v2
infixOp env OpLT   (Int  v1) (Int  v2) = return $ Bool $ v1 < v2
infixOp env OpLEq  (Int  v1) (Int  v2) = return $ Bool $ v1 <= v2
infixOp env OpGT   (Int  v1) (Int  v2) = return $ Bool $ v1 > v2
infixOp env OpGEq  (Int  v1) (Int  v2) = return $ Bool $ v1 >= v2
infixOp env OpLAnd (Bool v1) (Bool v2) = return $ Bool $ v1 && v2
infixOp env OpLOr  (Bool v1) (Bool v2) = return $ Bool $ v1 || v2
infixOp env OpEq   v1 v2 = return $ Bool $ v1 == v2
infixOp env OpNEq  v1 v2 = return $ Bool $ v1 /= v2

--
-- Environment and auxiliary functions
--

environment :: Environment
environment = Map.empty

index :: Index
index = []

stack :: Stack
stack = []

push :: String -> Value -> StateTransformer Value
push id v = ST $ \(StateT env i s) -> (v, (StateT env (id:i) (v:s)))

pop :: StateTransformer Value
pop = ST $ \(StateT env (i:is) (s:ss)) -> (s, (StateT env is ss))

put :: Index -> Stack -> String -> Value -> Stack
put (i:is) (s:ss) id val = if i == id then
		(val:ss)
	else
		(s:put is ss id val)
		
write :: String -> Value -> StateTransformer Value
write id val = ST $ \(StateT env index stack) -> (val, (StateT env index (put index stack id val)))

fetch :: Stack -> Index -> String -> (Maybe Value)
fetch [] [] _ = Nothing
fetch (s:ss) (i:is) id = if id == i then 
			(Just s)
		else 
			fetch ss is id
			
height :: StateTransformer Value
height = ST $ \(StateT env index stack) -> ((Int (length stack)), (StateT env index stack))

popTo :: Index -> Stack -> Int -> (Index, Stack)
popTo index stack n = if length stack == n then
		(index, stack)
	else 
		popTo (tail index) (tail stack) n

popLength :: Int -> StateTransformer Value
popLength n = ST $ \(StateT env i s) -> let (index, stack) = popTo i s n in 
	(Nil, (StateT env index stack))


stateLookup :: StateT -> String -> StateTransformer Value
stateLookup (StateT env index stack) var = ST $ \(StateT s i p) ->
    -- this way the error won't be skipped by lazy evaluation
		case fetch (stack++p) (index++i) var of
			Nothing -> 
			    case Map.lookup var (union s env) of
			        Nothing -> error $ "Variable " ++ show var ++ " not defiend."
			        Just val -> (val, (StateT s i p))
			Just v -> (v, (StateT s i p))
			

varDecl :: StateT -> VarDecl -> StateTransformer Value
varDecl env (VarDecl (Id id) maybeExpr) = do
    case maybeExpr of
        Nothing -> push id Nil
        (Just expr) -> do
            val <- evalExpr env expr
            push id val

setVar :: String -> Value -> StateTransformer Value
setVar var val = ST $ \(StateT s i p) -> (val, (StateT (insert var val s) i p))

--
-- Types and boilerplate
--

type Index = [String]
type Stack = [Value]
type Environment = Map String Value

data StateT = StateT Environment Index Stack
data StateTransformer t = ST (StateT -> (t, StateT))

instance Monad StateTransformer where
    return x = ST $ \s -> (x, s)
    (>>=) (ST m) f = ST $ \s ->
        let (v, newS) = m s
            (ST resF) = f v
        in resF newS

instance Functor StateTransformer where
    fmap = liftM

instance Applicative StateTransformer where
    pure = return
    (<*>) = ap

--
-- Main and results functions
--

showResult :: (Value, StateT) -> String
showResult (val, (StateT e i s)) =
    show val ++ "\n" ++ show (toList $ union e environment) ++ "\n" ++ show (zip i s) ++ "\n"

getResult :: StateTransformer Value -> (Value, StateT)
getResult (ST f) = f (StateT Map.empty [] [])

main :: IO ()
main = do
    js <- Parser.parseFromFile "Main.js"
    let statements = unJavaScript js
    putStrLn $ "AST: " ++ (show $ statements) ++ "\n"
    putStr $ showResult $ getResult $ evaluate (StateT environment index stack) statements
