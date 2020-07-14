;;========================================================;;
;;    BROWNIAN TREE (DLA) WITH HANDWRITTEN WEBASSEMBLY    ;;
;; `browniantree.wat` Lingdong Huang 2020   Public Domain ;;
;;========================================================;;
;;https://wikipedia.org/wiki/Diffusion-limited_aggregation;;
;;--------------------------------------------------------;;

(module

  ;; 4 pages = 4 x 64kb = max dimension 512x512 (pixel=1 byte)
  (memory $mem 4)

  ;; shr3 random number generator seed
  (global $jsr (mut i32) (i32.const 0x5EED))

  ;; shr3 random number generator
  (func $shr3 (result i32)
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shl   (global.get $jsr) (i32.const 17))))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shr_u (global.get $jsr) (i32.const 13))))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shl   (global.get $jsr) (i32.const 5 ))))
    (global.get $jsr)
  )
  (func $set_seed (param $seed i32) (global.set $jsr (local.get $seed)))
  
  ;; pixels are stored as 8-bit row-major array in memory
  ;; reading a pixel: mem[i=y*w+x]
  (func $get_pixel (param $w i32) (param $x i32) (param $y i32) (result i32)
    (i32.load8_u (i32.add
      (i32.mul (local.get $w) (local.get $y))
      (local.get $x)
    ))
  )

  ;; writing a pixel: mem[i=y*w+x]=v
  (func $set_pixel (param $w i32) (param $x i32) (param $y i32) (param $v i32)
    (i32.store8 (i32.add
      (i32.mul (local.get $w) (local.get $y))
      (local.get $x)
    ) (local.get $v))
  )
  
  ;; one iteration of brownian tree simulation:
  ;; - a particle starts at random location
  ;; - drunken walk in 8 directions
  ;; - upon hitting a neighboring on-pixel, turn on the current pixel and return
  ;; - upon going out of bounds, return
  ;; w: width, h: height
  (func $bt_iteration (param $w i32) (param $h i32)
    ;; local variable declaration
    ;; particle coordinate
    (local $x  i32) (local $y  i32)
    ;; random number
    (local $r  i32)
    ;; pixel Moore neighborhood
    (local $p2 i32) (local $p3 i32) (local $p4 i32) (local $p5 i32) 
    (local $p6 i32) (local $p7 i32) (local $p8 i32) (local $p9 i32)

    ;; random start location (x,y)=(rand()%w,rand()%h)
    (local.set $x (i32.rem_u (call $shr3) (local.get $w)))
    (local.set $y (i32.rem_u (call $shr3) (local.get $h)))
  
    loop
      ;; boundry conditions: exit
      (if (i32.eqz (local.get $x))                                        (then br 2 ))
      (if (i32.eqz (local.get $y))                                        (then br 2 ))
      (if (i32.eq  (local.get $x) (i32.sub (local.get $w) (i32.const 1))) (then br 2 ))
      (if (i32.eq  (local.get $y) (i32.sub (local.get $h) (i32.const 1))) (then br 2 ))

      ;; pixel's Moore (8-connected) neighborhood:

      ;; p9 p2 p3
      ;; p8    p4
      ;; p7 p6 p5
      (local.set $p2 (call $get_pixel (local.get $w)
                 (local.get $x)
        (i32.sub (local.get $y) (i32.const 1))
      ))
      (local.set $p3 (call $get_pixel (local.get $w)
        (i32.add (local.get $x) (i32.const 1))
        (i32.sub (local.get $y) (i32.const 1))
      ))
      (local.set $p4 (call $get_pixel (local.get $w)
        (i32.add (local.get $x) (i32.const 1))
                 (local.get $y)
      ))
      (local.set $p5 (call $get_pixel (local.get $w)
        (i32.add (local.get $x) (i32.const 1))
        (i32.add (local.get $y) (i32.const 1))
      ))
      (local.set $p6 (call $get_pixel (local.get $w)
                 (local.get $x)
        (i32.add (local.get $y) (i32.const 1))
      ))
      (local.set $p7 (call $get_pixel (local.get $w)
        (i32.sub (local.get $x) (i32.const 1))
        (i32.add (local.get $y) (i32.const 1))
      ))
      (local.set $p8 (call $get_pixel (local.get $w)
        (i32.sub (local.get $x) (i32.const 1))
                 (local.get $y)
      ))
      (local.set $p9 (call $get_pixel (local.get $w)
        (i32.sub (local.get $x) (i32.const 1))
        (i32.sub (local.get $y) (i32.const 1))
      ))

      ;; found a neighboring on-pixel
      (if (i32.or (i32.or (i32.or
        (i32.or (local.get $p2) (local.get $p3))
        (i32.or (local.get $p4) (local.get $p5)))
        (i32.or (local.get $p6) (local.get $p7)))
        (i32.or (local.get $p8) (local.get $p9)))
      (then 
        (call $set_pixel (local.get $w) (local.get $x) (local.get $y) (i32.const 1))
        br 2
      ))

      ;; generate random number in interval [0,8)
      ;; ==rand()%8
      (local.set $r (i32.rem_u (call $shr3) (i32.const 8)))

      ;; switch (r) case 0,1,...7
      ;; walk in one of the 8 directions
      (if (i32.eqz (local.get $r)) (then
        (local.set $x (i32.sub (local.get $x) (i32.const 1)))

      )(else(if (i32.eq (local.get $r) (i32.const 1)) (then
        (local.set $x (i32.add (local.get $x) (i32.const 1)))

      )(else(if (i32.eq (local.get $r) (i32.const 2)) (then
        (local.set $y (i32.sub (local.get $y) (i32.const 1)))

      )(else(if (i32.eq (local.get $r) (i32.const 3)) (then
        (local.set $y (i32.add (local.get $y) (i32.const 1)))

      )(else(if (i32.eq (local.get $r) (i32.const 4)) (then
        (local.set $x (i32.sub (local.get $x) (i32.const 1)))
        (local.set $y (i32.sub (local.get $y) (i32.const 1)))

      )(else(if (i32.eq (local.get $r) (i32.const 5)) (then
        (local.set $x (i32.sub (local.get $x) (i32.const 1)))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))

      )(else(if (i32.eq (local.get $r) (i32.const 6)) (then
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (local.set $y (i32.sub (local.get $y) (i32.const 1)))

      )(else
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
      ))))))))))))))
      (br 0)
    end

  )

  ;; simulate a batch of particles building the brownian tree
  ;; (just bt_iteration() in a loop)
  ;; w: width, h: height, n: number of particles
  (func $bt_batch (param $w i32) (param $h i32) (param $n i32)
    (local $i i32)
    loop $l0
      (call $bt_iteration (local.get $w) (local.get $h))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l0 (i32.lt_u (local.get $i) (local.get $n)))
    end
  )

  ;; exported API's
  (export "bt_iteration" (func $bt_iteration))
  (export "bt_batch"     (func $bt_batch))
  (export "get_pixel"    (func $get_pixel))
  (export "set_pixel"    (func $set_pixel))
  (export "shr3"         (func $shr3))
  (export "set_seed"     (func $set_seed))
  (export "mem"          (memory $mem))
)