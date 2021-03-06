module VMapAccum where

import CLaSH.Prelude

ha a b = (a `xor` b, a .&. b)

fa cin (a,b) = (cout,s)
  where
    (c1,z) = ha a b
    (c2,s) = ha z cin
    cout   = c1 .|. c2

topEntity :: Bit -> Vec 4 (Bit,Bit) -> ((Bit,Vec 4 Bit),(Bit, Vec 4 Bit))
topEntity acc xs = (vmapAccumL fa acc xs, vmapAccumR fa acc xs)
