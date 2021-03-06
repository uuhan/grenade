{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE ViewPatterns          #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Grenade.Recurrent.Layers.LSTM (
    LSTM (..)
  , LSTMWeights (..)
  , randomLSTM
  ) where

import           Control.Monad.Random ( MonadRandom, getRandom )

-- import           Data.List ( foldl1' )
import           Data.Proxy
import           Data.Serialize
import           Data.Singletons.TypeLits

import qualified Numeric.LinearAlgebra as LA
import           Numeric.LinearAlgebra.Static

import           Grenade.Core
import           Grenade.Recurrent.Core
import           Grenade.Layers.Internal.Update


-- | Long Short Term Memory Recurrent unit
--
--   This is a Peephole formulation, so the recurrent shape is
--   just the cell state, the previous output is not held or used
--   at all.
data LSTM :: Nat -> Nat -> * where
  LSTM :: ( KnownNat input
          , KnownNat output
          ) => !(LSTMWeights input output) -- Weights
            -> !(LSTMWeights input output) -- Momentums
            -> LSTM input output

data LSTMWeights :: Nat -> Nat -> * where
  LSTMWeights :: ( KnownNat input
                 , KnownNat output
                 ) => {
                   lstmWf :: !(L output input)  -- Weight Forget     (W_f)
                 , lstmUf :: !(L output output) -- Cell State Forget (U_f)
                 , lstmBf :: !(R output)        -- Bias Forget       (b_f)
                 , lstmWi :: !(L output input)  -- Weight Input      (W_i)
                 , lstmUi :: !(L output output) -- Cell State Input  (U_i)
                 , lstmBi :: !(R output)        -- Bias Input        (b_i)
                 , lstmWo :: !(L output input)  -- Weight Output     (W_o)
                 , lstmUo :: !(L output output) -- Cell State Output (U_o)
                 , lstmBo :: !(R output)        -- Bias Output       (b_o)
                 , lstmWc :: !(L output input)  -- Weight Cell       (W_c)
                 , lstmBc :: !(R output)        -- Bias Cell         (b_c)
                 } -> LSTMWeights input output

instance Show (LSTM i o) where
  show LSTM {} = "LSTM"

instance (KnownNat i, KnownNat o) => UpdateLayer (LSTM i o) where
  -- The gradients are the same shape as the weights and momentum
  -- This seems to be a general pattern, maybe it should be enforced.
  type Gradient (LSTM i o) = (LSTMWeights i o)

  -- Run the update function for each group matrix/vector of weights, momentums and gradients.
  -- Hmm, maybe the function should be used instead of passing in the learning parameters.
  runUpdate LearningParameters {..} (LSTM w m) g =
    let (wf, wf') = u lstmWf w m g
        (uf, uf') = u lstmUf w m g
        (bf, bf') = v lstmBf w m g
        (wi, wi') = u lstmWi w m g
        (ui, ui') = u lstmUi w m g
        (bi, bi') = v lstmBi w m g
        (wo, wo') = u lstmWo w m g
        (uo, uo') = u lstmUo w m g
        (bo, bo') = v lstmBo w m g
        (wc, wc') = u lstmWc w m g
        (bc, bc') = v lstmBc w m g
    in LSTM (LSTMWeights wf uf bf wi ui bi wo uo bo wc bc) (LSTMWeights wf' uf' bf' wi' ui' bi' wo' uo' bo' wc' bc')
      where
    -- Utility function for updating with the momentum, gradients, and weights.
    u :: forall x ix out. (KnownNat ix, KnownNat out) => (x -> (L out ix)) -> x -> x -> x -> ((L out ix), (L out ix))
    u e (e -> weights) (e -> momentum) (e -> gradient) =
      descendMatrix learningRate learningMomentum learningRegulariser weights gradient momentum

    v :: forall x ix. (KnownNat ix) => (x -> (R ix)) -> x -> x -> x -> ((R ix), (R ix))
    v e (e -> weights) (e -> momentum) (e -> gradient) =
      descendVector learningRate learningMomentum learningRegulariser weights gradient momentum

  -- There's a lot of updates here, so to try and minimise the number of data copies
  -- we'll create a mutable bucket for each.
  -- runUpdates rate lstm gs =
  --   let combinedGradient = foldl1' uu gs
  --   in  runUpdate rate lstm combinedGradient
  --     where
  --   uu :: (KnownNat i, KnownNat o) => LSTMWeights i o -> LSTMWeights i o -> LSTMWeights i o
  --   uu a b =
  --     let wf = u lstmWf a b
  --         uf = u lstmUf a b
  --         bf = v lstmBf a b
  --         wi = u lstmWi a b
  --         ui = u lstmUi a b
  --         bi = v lstmBi a b
  --         wo = u lstmWo a b
  --         uo = u lstmUo a b
  --         bo = v lstmBo a b
  --         wc = u lstmWc a b
  --         bc = v lstmBc a b
  --     in LSTMWeights wf uf bf wi ui bi wo uo bo wc bc
  --   u :: forall x ix out. (KnownNat ix, KnownNat out) => (x -> (L out ix)) -> x -> x -> L out ix
  --   u e (e -> a) (e -> b) = tr $ tr a + tr b

  --   v :: forall x ix. (x -> (R ix)) -> x -> x -> R ix
  --   v e (e -> a) (e -> b) = a + b
  createRandom = randomLSTM

instance (KnownNat i, KnownNat o) => RecurrentUpdateLayer (LSTM i o) where
  -- The recurrent shape is the same size as the output.
  -- It's actually the cell state however, as this is a peephole variety LSTM.
  type RecurrentShape (LSTM i o) = S ('D1 o)

instance (KnownNat i, KnownNat o) => RecurrentLayer (LSTM i o) ('D1 i) ('D1 o) where

  type RecTape (LSTM i o) ('D1 i) ('D1 o) = (S ('D1 o), S ('D1 i))
  -- Forward propagation for the LSTM layer.
  -- The size of the cell state is also the size of the output.
  runRecurrentForwards (LSTM (LSTMWeights {..}) _) (S1D cell) (S1D input) =
    let -- Forget state vector
        f_t = sigmoid $ lstmBf + lstmWf #> input + lstmUf #> cell
        -- Input state vector
        i_t = sigmoid $ lstmBi + lstmWi #> input + lstmUi #> cell
        -- Output state vector
        o_t = sigmoid $ lstmBo + lstmWo #> input + lstmUo #> cell
        -- Cell input state vector
        c_x = tanh    $ lstmBc + lstmWc #> input
        -- Cell state
        c_t = f_t * cell + i_t * c_x
        -- Output (it's sometimes recommended to use tanh c_t)
        h_t = o_t * c_t
    in ((S1D cell, S1D input), S1D c_t, S1D h_t)

  -- Run a backpropogation step for an LSTM layer.
  -- We're doing all the derivatives by hand here, so one should
  -- be extra careful when changing this.
  --
  -- There's a test version using the AD library without hmatrix in the test
  -- suite. These should match always.
  runRecurrentBackwards (LSTM (LSTMWeights {..}) _) (S1D cell, S1D input) (S1D cellGrad) (S1D h_t') =
    -- We're not keeping the Wengert tape during the forward pass,
    -- so we're duplicating some work here.
    --
    -- If I was being generous, I'd call it checkpointing.
    --
    -- Maybe think about better ways to store some intermediate states.
    let -- Forget state vector
        f_s = lstmBf + lstmWf #> input + lstmUf #> cell
        f_t = sigmoid f_s
        -- Input state vector
        i_s = lstmBi + lstmWi #> input + lstmUi #> cell
        i_t = sigmoid i_s
        -- Output state vector
        o_s = lstmBo + lstmWo #> input + lstmUo #> cell
        o_t = sigmoid o_s
        -- Cell input state vector
        c_s = lstmBc + lstmWc #> input
        c_x = tanh c_s
        -- Cell state
        c_t = f_t * cell + i_t * c_x

        -- Reverse Mode AD Derivitives
        c_t' = h_t' * o_t + cellGrad

        f_t' = c_t' * cell
        f_s' = sigmoid' f_s * f_t'

        o_t' = h_t' * c_t
        o_s' = sigmoid' o_s * o_t'

        i_t' = c_t' * c_x
        i_s' = sigmoid' i_s * i_t'

        c_x' = c_t' * i_t
        c_s' = tanh' c_s * c_x'

        -- The derivatives to pass sideways (recurrent) and downwards
        cell'  = tr lstmUf #> f_s' + tr lstmUo #> o_s' + tr lstmUi #> i_s' + c_t' * f_t
        input' = tr lstmWf #> f_s' + tr lstmWo #> o_s' + tr lstmWi #> i_s' + tr lstmWc #> c_s'

        -- Calculate the gradient Matricies for the input
        lstmWf' = f_s' `outer` input
        lstmWi' = i_s' `outer` input
        lstmWo' = o_s' `outer` input
        lstmWc' = c_s' `outer` input

        -- Calculate the gradient Matricies for the cell
        lstmUf' = f_s' `outer` cell
        lstmUi' = i_s' `outer` cell
        lstmUo' = o_s' `outer` cell

        -- The biases just get the values, but we'll write it so it's obvious
        lstmBf' = f_s'
        lstmBi' = i_s'
        lstmBo' = o_s'
        lstmBc' = c_s'

        gradients = LSTMWeights lstmWf' lstmUf' lstmBf' lstmWi' lstmUi' lstmBi' lstmWo' lstmUo' lstmBo' lstmWc' lstmBc'
    in  (gradients, S1D cell', S1D input')

-- | Generate an LSTM layer with random Weights
--   one can also just call createRandom from UpdateLayer
--
--   Has forget gate biases set to 1 to encourage early learning.
--
--   https://github.com/karpathy/char-rnn/commit/0dfeaa454e687dd0278f036552ea1e48a0a408c9
--
randomLSTM :: forall m i o. (MonadRandom m, KnownNat i, KnownNat o)
           => m (LSTM i o)
randomLSTM = do
    let w = (\s -> uniformSample s (-1) 1 ) <$> getRandom
        u = (\s -> uniformSample s (-1) 1 ) <$> getRandom
        v = (\s -> randomVector s Uniform * 2 - 1) <$> getRandom

        w0 = konst 0
        u0 = konst 0
        v0 = konst 0

    LSTM <$> (LSTMWeights <$> w <*> u <*> pure (konst 1) <*> w <*> u <*> v <*> w <*> u <*> v <*> w <*> v)
         <*> pure (LSTMWeights w0 u0 v0 w0 u0 v0 w0 u0 v0 w0 v0)

-- | Maths
--
-- TODO: move to not here
sigmoid :: Floating a => a -> a
sigmoid x = 1 / (1 + exp (-x))

sigmoid' :: Floating a => a -> a
sigmoid' x = logix * (1 - logix)
  where
    logix = sigmoid x

tanh' :: (Floating a) => a -> a
tanh' t = 1 - s ^ (2 :: Int)  where s = tanh t

instance (KnownNat i, KnownNat o) => Serialize (LSTM i o) where
  put (LSTM LSTMWeights {..} _) = do
    u lstmWf
    u lstmUf
    v lstmBf
    u lstmWi
    u lstmUi
    v lstmBi
    u lstmWo
    u lstmUo
    v lstmBo
    u lstmWc
    v lstmBc
      where
    u :: forall a b. (KnownNat a, KnownNat b) => Putter  (L b a)
    u = putListOf put . LA.toList . LA.flatten . extract
    v :: forall a. (KnownNat a) => Putter (R a)
    v = putListOf put . LA.toList . extract

  get = do
    lstmWf <- u
    lstmUf <- u
    lstmBf <- v
    lstmWi <- u
    lstmUi <- u
    lstmBi <- v
    lstmWo <- u
    lstmUo <- u
    lstmBo <- v
    lstmWc <- u
    lstmBc <- v
    return $ LSTM (LSTMWeights {..}) (LSTMWeights w0 u0 v0 w0 u0 v0 w0 u0 v0 w0 v0)
      where
    u :: forall a b. (KnownNat a, KnownNat b) => Get  (L b a)
    u = let f = fromIntegral $ natVal (Proxy :: Proxy a)
        in  maybe (fail "Vector of incorrect size") return . create . LA.reshape f . LA.fromList =<< getListOf get
    v :: forall a. (KnownNat a) => Get (R a)
    v = maybe (fail "Vector of incorrect size") return . create . LA.fromList =<< getListOf get

    w0 = konst 0
    u0 = konst 0
    v0 = konst 0
