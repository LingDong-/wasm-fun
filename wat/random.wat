;;========================================================;;
;;   NOISES AND RANDOMNESS IN HANDWRITTEN WEBASSEMBLY     ;;
;;  `random.wat`   Lingdong Huang 2020   Public Domain    ;;
;;========================================================;;
;;   Uniform, Perlin, Gaussian, Exponential Randomness    ;;
;;--------------------------------------------------------;;

(module

  (memory $mem 1) ;; 64K

  ;; MEMORY LAYOUT (total 20,992 bytes)
  ;; -----------------------------------------
  ;; 4608  bytes | ziggurat lookup tables
  ;;   -> i32 kn[128], ke[256]
  ;;   -> f32 wn[128], fn[128],we[256],fe[256]
  ;; -----------------------------------------
  ;; 16384 bytes | perlin lookup table
  ;;   -> f32 [4096]
  ;; -----------------------------------------

  ;; perlin noise constants
  (global $PERLIN_YWRAPB i32 (i32.const 4   ))
  (global $PERLIN_YWRAP  i32 (i32.const 16  )) ;; 1<<PERLIN_YWRAPB
  (global $PERLIN_ZWRAPB i32 (i32.const 8   ))
  (global $PERLIN_ZWRAP  i32 (i32.const 256 )) ;; 1<<PERLIN_ZWRAPB
  (global $PERLIN_SIZE   i32 (i32.const 4095)) ;; 2^?-1

  ;; math constants
  (global $PI      f32 (f32.const 3.1415926536))
  (global $TAU     f32 (f32.const 6.2831853072)) ;; 2*PI
  (global $INV_TAU f32 (f32.const 0.1591549431)) ;; 1/(2*PI)

  ;; perlin configs
  (global $PERLIN_OCTAVES     (mut i32) (i32.const 4  ))
  (global $PERLIN_AMP_FALLOFF (mut f32) (f32.const 0.5))

  (global $perlin_ptr          i32  (i32.const 4608)) ;; pointer to perlin table
                                                      ;; first 1152 bytes reserved for ziggurat 

  ;;====================================================================
  ;; Shared utils
  ;;====================================================================

  ;; shr3 random number generator seed
  (global $jsr (mut i32) (i32.const 0x5EED))
  (global $jz  (mut i32) (i32.const 0))

  ;; other ziggurat globals
  (global $iz (mut i32) (i32.const 0))
  (global $hz (mut i32) (i32.const 0))

  ;; shr3 random number generator
  (func $shr3 (result i32)
    (global.set $jz (global.get $jsr))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shl   (global.get $jsr) (i32.const 13))))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shr_u (global.get $jsr) (i32.const 17))))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shl   (global.get $jsr) (i32.const 5 ))))
    (i32.add (global.get $jz) (global.get $jsr))
  )
  ;; uniform randomness between [0,1]
  (func $uni (result f32)
    (f32.add
      (f32.const 0.5)
      (f32.mul (f32.convert_i32_s (call $shr3)) (f32.const 0.2328306e-9))
    )
  )
  ;; fast and crappy cosine approximation for [-pi,pi]
  (func $cos_approx (param $x f32) (result f32)
    ;; adapted from https://stackoverflow.com/a/28050328
    (local.set $x (f32.mul (local.get $x) (global.get $INV_TAU)))
    (local.set $x (f32.sub (local.get $x) (f32.add 
      (f32.const 0.25) 
      (f32.floor (f32.add (local.get $x (f32.const 0.25))))
    )))
    (local.set $x (f32.mul (local.get $x) (f32.mul 
      (f32.const 16.0)
      (f32.sub (f32.abs (local.get $x)) (f32.const 0.5) )
    )))
    (local.get $x)
  )
  ;; float mod
  (func $fmod (param $x f32) (param $y f32) (result f32)
    (f32.sub (local.get $x) (f32.mul 
      (local.get $y) 
      (f32.trunc (f32.div (local.get $x) (local.get $y)))
    ))
  )
  ;; consine function
  ;; use periodic property to fall in range [-pi,pi] for cos_approx
  (func $cos (param $x f32) (result f32)
    (f32.neg (call $cos_approx (f32.sub (call $fmod (local.get $x) (global.get $TAU)) (global.get $PI) ) ))
  )

  ;; natural log ln(x) approximation
  (func $log (param $x f32) (result f32)
    ;; https://gist.github.com/LingDong-/7e4c4cae5cbbc44400a05fba65f06f23

    (local $bx i32)
    (local $ex i32)
    (local $t  i32)
    (local $s  i32)
    (local.set $bx (i32.reinterpret_f32 (local.get $x)))
    (local.set $ex (i32.shr_u (local.get $bx) (i32.const 23)))
    (local.set $t (i32.sub (local.get $ex) (i32.const 127)))
    (local.set $s (local.get $t))
    (if (i32.lt_s (local.get $t) (i32.const 0)) (then
      (local.set $s (i32.sub (i32.const 0) (local.get $t) ))
    ))
    (local.set $bx (i32.or 
      (i32.const 1065353216)  
      (i32.and (local.get $bx) (i32.const 8388607) )
    ))
    (local.set $x (f32.reinterpret_i32 (local.get $bx) ))

    (f32.add 
                 (f32.add (f32.const -1.49278)
        (f32.mul (f32.add (f32.const 2.11263)
        (f32.mul (f32.add (f32.const -0.729104)
                 (f32.mul (f32.const 0.10969) 
                          (local.get $x)))
                          (local.get $x)))
                          (local.get $x)))

      (f32.mul
        (f32.convert_i32_s (local.get $t))
        (f32.const 0.6931471806)
      )
    )
  )

  ;; natural exponent e^x approximation
  (func $exp (param $x f32) (result f32)
    ;; adapted from https://stackoverflow.com/a/50425370
    (local $m i32)
    (local $i i32)
    (local.set $i (i32.add
      (i32.trunc_f32_s (f32.mul (local.get $x) (f32.const 12102203.0))  )
      (i32.const 1065353216)
    ))
    (local.set $m (i32.and 
      (i32.shr_u (local.get $i) (i32.const 7))
      (i32.const 0xffff) 
    ))
    (local.set $i (i32.add (local.get $i)
      (i32.sub (i32.shr_s  (i32.mul
      (i32.sub (i32.shr_s  (i32.mul
      (i32.add (i32.shr_s  (i32.mul 
        (i32.const 1277 )  (local.get $m)) (i32.const 14))
        (i32.const 14825)) (local.get $m)) (i32.const 14))
        (i32.const 79749)) (local.get $m)) (i32.const 11))
        (i32.const 626  ))
    ))
    (f32.reinterpret_i32 (local.get $i))
  )


  ;;====================================================================
  ;; Perlin noise
  ;; ADAPTED FROM:
  ;;   https://github.com/processing/p5.js/blob/master/src/math/noise.js
  ;; WHICH WAS ADAPTED FROM:
  ;;   https://www.kuehlbox.wtf/download/demos/farbrausch/fr010src.zip
  ;;====================================================================

  (func $scaled_cos (param $i f32) (result f32)
    (f32.mul
      (f32.const 0.5) 
      ( f32.sub (f32.const 1.0) (call $cos (f32.mul (global.get $PI) (local.get $i))) )
    )
  )

  ;; set perlin noise seed
  ;; fills a lookup table with random(0,1)
  (func $pnseed (param $seed i32)
    (local $i i32)
    (local $n i32)
    (local.set $n (i32.add (global.get $PERLIN_SIZE) (i32.const 1)))
    (global.set $jsr (local.get $seed))
    (local.set $i (i32.const 0))
    loop $l0
      (f32.store
        (i32.add (global.get $perlin_ptr) (i32.shl (local.get $i) (i32.const 2)))
        (call $uni)
      )
      (local.set $i (i32.add (local.get $i (i32.const 1))))
      (br_if $l0 (i32.lt_u (local.get $i) (local.get $n)))
    end
  )

  (func $pndetail (param $lod i32) (param $falloff f32)
    (global.set $PERLIN_OCTAVES (local.get $lod))
    (global.set $PERLIN_AMP_FALLOFF (local.get $falloff))
  )

  ;; helper to read a float from lookup table
  (func $perlin_lookup (param $i i32) (result f32)
    (f32.load (i32.add (global.get $perlin_ptr) (i32.shl
      (i32.and (local.get $i) (global.get $PERLIN_SIZE))
      (i32.const 2)
    )))
  )

  ;; main perlin noise function:
  ;; sample noise at (x,y,z)
  (func $pnoise (param $x f32) (param $y f32) (param $z f32) (result f32)
    (local $xi i32) (local $yi i32) (local $zi i32) 
    (local $o i32) (local $of i32)

    (local $xf f32) (local $yf f32) (local $zf f32) 
    (local $rxf f32) (local $ryf f32) (local $r f32) (local $ampl f32)
    (local $n1 f32) (local $n2 f32) (local $n3 f32)

    (local.set $x (f32.abs (local.get $x)))
    (local.set $y (f32.abs (local.get $y)))
    (local.set $z (f32.abs (local.get $z)))

    (local.set $xi (i32.trunc_f32_u (local.get $x)))
    (local.set $yi (i32.trunc_f32_u (local.get $y)))
    (local.set $zi (i32.trunc_f32_u (local.get $z)))

    (local.set $xf (f32.sub (local.get $x) (f32.trunc (local.get $x) ) ))
    (local.set $yf (f32.sub (local.get $y) (f32.trunc (local.get $y) ) ))
    (local.set $zf (f32.sub (local.get $z) (f32.trunc (local.get $z) ) ))

    (local.set $r (f32.const 0))
    (local.set $ampl (f32.const 0.5))

    loop $l0

      (local.set $of (i32.add 
        (i32.add (local.get $xi) (i32.shl (local.get $yi) (global.get $PERLIN_YWRAPB)))
                                 (i32.shl (local.get $zi) (global.get $PERLIN_ZWRAPB))
      ))

      (local.set $rxf (call $scaled_cos (local.get $xf)))
      (local.set $ryf (call $scaled_cos (local.get $yf)))

      (local.set $n1 (call $perlin_lookup (local.get $of) ))

      (local.set $n1 (f32.add (local.get $n1)
        (f32.mul 
          (local.get $rxf) 
          (f32.sub
            (call $perlin_lookup (i32.add (local.get $of) (i32.const 1)) )
            (local.get $n1)
          )
        )
      ))

      (local.set $n2 (call $perlin_lookup (i32.add (local.get $of) (global.get $PERLIN_YWRAP)) ))
      (local.set $n2 (f32.add (local.get $n2)
        (f32.mul 
          (local.get $rxf) 
          (f32.sub
            (call $perlin_lookup 
              (i32.add (i32.add (local.get $of) (global.get $PERLIN_YWRAP)) (i32.const 1)) 
            )
            (local.get $n2)
          )
        )
      ))

      (local.set $n1 (f32.add (local.get $n1) (f32.mul 
        (local.get $ryf) 
        (f32.sub (local.get $n2) (local.get $n1)) 
      )))
      
      (local.set $of (i32.add (local.get $of) (global.get $PERLIN_ZWRAP) ))

      (local.set $n2 (call $perlin_lookup (local.get $of)))
      (local.set $n2 (f32.add (local.get $n2)
        (f32.mul 
          (local.get $rxf) 
          (f32.sub
            (call $perlin_lookup (i32.add (local.get $of) (i32.const 1)) )
            (local.get $n2)
          )
        )
      ))

      (local.set $n3 (call $perlin_lookup (i32.add (local.get $of) (global.get $PERLIN_YWRAP)) ))
      (local.set $n3 (f32.add (local.get $n3)
        (f32.mul 
          (local.get $rxf) 
          (f32.sub
            (call $perlin_lookup 
              (i32.add (i32.add (local.get $of) (global.get $PERLIN_YWRAP)) (i32.const 1)) 
            )
            (local.get $n3)
          )
        )
      ))    
      (local.set $n2 (f32.add (local.get $n2) (f32.mul 
        (local.get $ryf) 
        (f32.sub (local.get $n3) (local.get $n2)) 
      )))

      (local.set $n1 (f32.add (local.get $n1)
        (f32.mul 
          (call $scaled_cos (local.get $zf))
          (f32.sub (local.get $n2) (local.get $n1))
        )
      ))

      (local.set $r (f32.add (local.get $r)
        (f32.mul (local.get $n1) (local.get $ampl))
      ))

      (local.set $ampl (f32.mul (local.get $ampl) (global.get $PERLIN_AMP_FALLOFF) ))


      (local.set $xi (i32.shl (local.get $xi) (i32.const 1) ))
      (local.set $yi (i32.shl (local.get $yi) (i32.const 1) ))
      (local.set $zi (i32.shl (local.get $zi) (i32.const 1) ))

      (local.set $xf (f32.mul (local.get $xf) (f32.const 2.0) ))
      (local.set $yf (f32.mul (local.get $yf) (f32.const 2.0) ))
      (local.set $zf (f32.mul (local.get $zf) (f32.const 2.0) ))

      (if (f32.lt (local.get $xf) (f32.const 1.0)) (then) (else
        (local.set $xi (i32.add (local.get $xi) (i32.const 1)))
        (local.set $xf (f32.sub (local.get $xf) (f32.const 1)))
      ))

      (if (f32.lt (local.get $yf) (f32.const 1.0)) (then) (else
        (local.set $yi (i32.add (local.get $yi) (i32.const 1)))
        (local.set $yf (f32.sub (local.get $yf) (f32.const 1)))
      ))

      (if (f32.lt (local.get $zf) (f32.const 1.0)) (then) (else
        (local.set $zi (i32.add (local.get $zi) (i32.const 1)))
        (local.set $zf (f32.sub (local.get $zf) (f32.const 1)))
      ))

      (local.set $o (i32.add (local.get $o (i32.const 1))))
      (br_if $l0 (i32.lt_u (local.get $o) (global.get $PERLIN_OCTAVES)))
    end

    (local.get $r)
  )

  ;;====================================================================
  ;; Gaussian and Exponential randomness using Ziggurat algorithm
  ;; ADAPTED FROM:
  ;;   The Ziggurat Method for Generating Random Variables
  ;;   George Marsaglia; Wai Wan Tsang (2000)
  ;;   https://core.ac.uk/download/pdf/6287927.pdf
  ;;====================================================================

  ;; table reader and writers

  ;; kn : i32[128]
  (func $kn_read (param $i i32) (result i32)
    (i32.load
      (i32.shl (local.get $i) (i32.const 2))
    )
  )
  (func $kn_write (param $i i32) (param $v i32)
    (i32.store
      (i32.shl (local.get $i) (i32.const 2))
      (local.get $v))
  )
  ;; ke : i32[256]
  (func $ke_read (param $i i32) (result i32)
    (i32.load (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 512)
    ))
  )
  (func $ke_write (param $i i32) (param $v i32)
    (i32.store (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 512)
    ) (local.get $v))
  )
  ;; wn : f32[128]
  (func $wn_read (param $i i32) (result f32)
    (f32.load (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 1536)
    ))
  )
  (func $wn_write (param $i i32) (param $v f32)
    (f32.store (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 1536)
    ) (local.get $v))
  )
  ;; fn : f32[128]
  (func $fn_read (param $i i32) (result f32)
    (f32.load (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 2048)
    ))
  )
  (func $fn_write (param $i i32) (param $v f32)
    (f32.store (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 2048)
    ) (local.get $v))
  )
  ;; we : f32[256]
  (func $we_read (param $i i32) (result f32)
    (f32.load (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 2560)
    ))
  )
  (func $we_write (param $i i32) (param $v f32)
    (f32.store (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 2560)
    ) (local.get $v))
  )
  ;; fe : f32[256]
  (func $fe_read (param $i i32) (result f32)
    (f32.load (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 3584)
    ))
  )
  (func $fe_write (param $i i32) (param $v f32)
    (f32.store (i32.add
      (i32.shl (local.get $i) (i32.const 2))
      (i32.const 3584)
    ) (local.get $v))
  )

  ;; provides RNOR if $rnor cannot
  (func $nfix (result f32)
    (local $r f32)
    (local $x f32)
    (local $y f32)
    (local $fhz f32)

    (local.set $r (f32.const 3.442620))

    loop $l0
      (local.set $x (f32.mul 
        (f32.convert_i32_s (global.get $hz))
        (call $wn_read (global.get $iz))
      ))
      (if (i32.eqz (global.get $iz)) (then
        loop $l1
          (local.set $x (f32.mul (call $log (call $uni)) (f32.const -0.2904764)))
          (local.set $y (f32.neg (call $log (call $uni))))

          (br_if $l1 (f32.lt 
            (f32.add (local.get $y) (local.get $y) )
            (f32.mul (local.get $x) (local.get $x) )
          ))
        end
        (if (i32.gt_s (global.get $hz) (i32.const 0) ) (then
          (f32.add (local.get $r) (local.get $x))
          return
        )(else
          (f32.neg (f32.add (local.get $r) (local.get $x)))
          return
        ))
      ))
      (if (f32.lt
        (f32.add
          (call $fn_read (global.get $iz))
          (f32.mul
            (call $uni)
            (f32.sub
              (call $fn_read (i32.sub (global.get $iz) (i32.const 1)))
              (call $fn_read (global.get $iz))
            )
          )
        )
        (call $exp 
          (f32.mul (f32.mul (f32.const -0.5) (local.get $x)) (local.get $x))
        )
      )(then
        (local.get $x)
        return
      ))

      (global.set $hz (call $shr3))
      (global.set $iz (i32.and (global.get $hz) (i32.const 127)))

      (local.set $fhz (f32.convert_i32_s (global.get $hz)))
      (if (i32.lt_u
        (i32.trunc_f32_u (f32.abs (local.get $fhz)))
        (call $kn_read (global.get $iz))
      )(then
        (f32.mul
          (local.get $fhz)
          (call $wn_read (global.get $iz))
        )
        return
      ))
      (br $l0)
    end

    (f32.const 0)
  )

  ;;provides REXP if $rexp cannot
  (func $efix (result f32)
    (local $x f32)
    loop $l0
      (if (i32.eqz (global.get $iz))(then
        (f32.sub (f32.const 7.69711) (call $log (call $uni)))
        return
      ))
      (local.set $x (f32.mul 
        (f32.convert_i32_u (global.get $jz))
        (call $we_read (global.get $iz))
      ))
      (if (f32.lt
        (f32.add
          (call $fe_read (global.get $iz))
          (f32.mul
            (call $uni)
            (f32.sub
              (call $fe_read (i32.sub (global.get $iz) (i32.const 1) ) )
              (call $fe_read (global.get $iz) )
            )
          )
        )
        (call $exp (f32.neg (local.get $x)))
      )(then
        (local.get $x)
        return
      ))
      (global.set $jz (call $shr3))
      (global.set $iz (i32.and (global.get $jz) (i32.const 255) ))
      (if (i32.lt_u (global.get $jsr) (call $ke_read (global.get $iz) ) )(then
        (f32.mul
          (f32.convert_i32_u (global.get $jz))
          (call $we_read (global.get $iz))
        )
        return
      ))
      (br $l0)
    end
    (f32.const 0)
  )

  ;; the main gaussian randomness function
  (func $rnor (result f32)
    (local $fhz f32)
    (global.set $hz (call $shr3))
    (global.set $iz (i32.and (global.get $hz) (i32.const 127) ))
    
    (local.set $fhz (f32.convert_i32_s (global.get $hz)))
    (if (i32.lt_u
      (i32.trunc_f32_u (f32.abs (local.get $fhz)))
      (call $kn_read (global.get $iz))
    )(then
      (f32.mul
        (local.get $fhz)
        (call $wn_read (global.get $iz))
      )
      return
    )(else
      (call $nfix)
      return
    ))
    (f32.const 0)
    return
  )

  ;; the main exponential randomness function
  (func $rexp (result f32)
    (global.set $jz (call $shr3))
    (global.set $iz (i32.and (global.get $jz) (i32.const 255) ))
    
    (if (i32.lt_u
      (global.get $jz)
      (call $kn_read (global.get $iz))
    )(then
      (f32.mul
        (f32.convert_i32_u (global.get $jz))
        (call $we_read (global.get $iz))
      )
      return
    )(else
      (call $efix)
      return
    ))
    (f32.const 0)
    return
  )

  ;; This procedure sets the seed and creates the tables
  (func $zigset (param $jsrseed i32)
    (local $m1 f32) (local $m2 f32)
    (local $dn f32) (local $tn f32) (local $vn f32) (local $q f32)
    (local $de f32) (local $te f32) (local $ve f32)
    (local $i  i32)

    (local.set $m1 (f32.const 2147483648.0))
    (local.set $m2 (f32.const 4294967296.0))
    (local.set $dn (f32.const 3.442619855899))
    (local.set $tn (local.get $dn))
    (local.set $vn (f32.const 9.91256303526217e-3))
    (local.set $de (f32.const 7.697117470131487))
    (local.set $te (local.get $de))
    (local.set $ve (f32.const 3.949659822581572e-3))

    (global.set $jsr (local.get $jsrseed))

    ;; Tables for RNOR
    (local.set $q (f32.div (local.get $vn)
      (call $exp
        (f32.mul (f32.mul (f32.const -0.5) (local.get $dn)) (local.get $dn))
      )
    ))

    (call $kn_write (i32.const 0)
      (i32.trunc_f32_u (f32.mul
        (f32.div (local.get $dn) (local.get $q))
        (local.get $m1)
      ))
    )
    (call $kn_write (i32.const 1) (i32.const 0))
    (call $wn_write (i32.const 0)
      (f32.div (local.get $q) (local.get $m1) )
    )
    (call $wn_write (i32.const 127) 
      (f32.div (local.get $dn) (local.get $m1) )
    )
    (call $fn_write (i32.const 0) (f32.const 1.0))
    (call $fn_write (i32.const 127) 
      (call $exp
        (f32.mul (f32.mul (f32.const -0.5) (local.get $dn)) (local.get $dn))
      )
    )
    (local.set $i (i32.const 126))
    loop $l0
      (local.set $dn 
        (f32.sqrt (f32.mul
          (f32.const -2)
          (call $log (f32.add
            (f32.div (local.get $vn) (local.get $dn))
            (call $exp
              (f32.mul (f32.mul (f32.const -0.5) (local.get $dn)) (local.get $dn))
            )
          ))
        ))
      )
      (call $kn_write (i32.add (local.get $i) (i32.const 1)) (i32.trunc_f32_u
        (f32.mul (f32.div (local.get $dn) (local.get $tn)) (local.get $m1))
      ))
      (local.set $tn (local.get $dn))
      (call $fn_write (local.get $i)
        (call $exp
          (f32.mul (f32.mul (f32.const -0.5) (local.get $dn)) (local.get $dn))
        )
      )
      (call $wn_write (local.get $i)
        (f32.div (local.get $dn) (local.get $m1))
      )

      (local.set $i (i32.sub (local.get $i) (i32.const 1) ))
      (br_if $l0 (i32.gt_s (local.get $i) (i32.const 0)))
    end

    ;; Tables for REXP

    (local.set $q (f32.div (local.get $ve)
      (call $exp
        (f32.neg (local.get $de))
      )
    ))

    (call $ke_write (i32.const 0)
      (i32.trunc_f32_u (f32.mul
        (f32.div (local.get $de) (local.get $q))
        (local.get $m2)
      ))
    )
    (call $ke_write (i32.const 1) (i32.const 0))
    (call $we_write (i32.const 0)
      (f32.div (local.get $q) (local.get $m2) )
    )
    (call $we_write (i32.const 255) 
      (f32.div (local.get $de) (local.get $m2) )
    )
    (call $fe_write (i32.const 0) (f32.const 1.0))
    (call $fe_write (i32.const 255)
      (call $exp (f32.neg (local.get $de)))
    )
    
    (local.set $i (i32.const 254))
    loop $l1

      (local.set $de (f32.neg
        (call $log (f32.add
          (f32.div (local.get $ve) (local.get $de))
          (call $exp (f32.neg (local.get $de)) )
        ))
      ))
      (call $ke_write (i32.add (local.get $i) (i32.const 1) ) (i32.trunc_f32_u
        (f32.mul (f32.div (local.get $de) (local.get $te) ) (local.get $m2) )
      ))
      (local.set $te (local.get $de))
      (call $fe_write (local.get $i) (call $exp (f32.neg (local.get $de))))
      (call $we_write (local.get $i) (f32.div (local.get $de) (local.get $m2)))

      (local.set $i (i32.sub (local.get $i) (i32.const 1) ))
      (br_if $l1 (i32.gt_s (local.get $i) (i32.const 0)))
    end
  )

  ;; set random seed
  (func $seed (param $jsrseed i32)
    (global.set $jsr (local.get $jsrseed))
  )

  ;; exported API's
  (export "mem"      (memory $mem        ))
  (export "fmod"     (func $fmod         ))
  (export "log"      (func $log          ))
  (export "cos"      (func $cos          ))
  (export "exp"      (func $exp          ))
  (export "shr3"     (func $shr3         ))
  (export "pnoise"   (func $pnoise       ))
  (export "pnseed"   (func $pnseed       ))
  (export "pndetail" (func $pndetail     ))
  (export "uni"      (func $uni          ))
  (export "rnor"     (func $rnor         ))
  (export "rexp"     (func $rexp         ))
  (export "zigset"   (func $zigset       ))
  (export "seed"     (func $seed         ))


)
