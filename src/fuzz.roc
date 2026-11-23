app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst" }

import fuzz.Fuzz
import FuzzSolver
import FuzzDimacs

target = Fuzz.suite([FuzzSolver.suite, FuzzDimacs.suite])
