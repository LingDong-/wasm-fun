;;========================================================;;
;;    DISTANCE TRANSFORM WITH HANDWRITTEN WEBASSEMBLY     ;;
;; `disttransform.wat` Lingdong Huang 2020  Public Domain ;;
;;========================================================;;
;; Computing distance transform of binary images          ;;
;; Implements Meijster-Roerdink-Hesselink algorithm       ;;
;; fab.cba.mit.edu/classes/S62.12/docs/Meijster_distance.pdf
;;--------------------------------------------------------;;

(module

  (memory $mem 64)

  ;; memory layout
  ;;0_________________INPUT___________________
  ;;| m x n bytes <uchar> input image
  ;;|_________________OUTPUT__________________
  ;;| m x n x 4 bytes <int> distance transform
  ;;|_______________INTERNALS_________________
  ;;| m x n x 4 bytes <int> g matrix
  ;;|.........................................
  ;;| m x 4 bytes <int> s vector
  ;;|.........................................
  ;;| m x 4 bytes <int> t vector
  ;;|_________________________________________

  (global $m         (mut i32) (i32.const 512    )) ;; width
  (global $n         (mut i32) (i32.const 512    )) ;; height
  (global $dt_offset (mut i32) (i32.const 262144 )) ;; memory offsets
  (global $g_offset  (mut i32) (i32.const 1370720)) ;; ..
  (global $s_offset  (mut i32) (i32.const 2359296)) ;; ..
  (global $t_offset  (mut i32) (i32.const 2361344)) ;; ..

  ;; getters and setters for accessing differerent matrices in memory
  ;; basically: offset + ( y * width + x ) * element_size
  
  ;; read input image at coordinate
  (func $get_b (param $x i32) (param $y i32) (result i32)
    (i32.load8_u (i32.add
      (i32.mul (global.get $m) (local.get $y))
      (local.get $x)
    ))
  )
  ;; write input image at coordinate
  (func $set_b (param $x i32) (param $y i32) (param $v i32)
    (i32.store8 (i32.add
      (i32.mul (global.get $m) (local.get $y))
      (local.get $x)
    ) (local.get $v))
  )
  ;; read output distance transform at coordinate
  (func $get_dt (param $x i32) (param $y i32) (result i32)
    (i32.load (i32.add (global.get $dt_offset) (i32.mul 
      (i32.add (i32.mul (global.get $m) (local.get $y)) (local.get $x)) 
      (i32.const 4)
    )))
  )
  ;; write output distance transform at coordinate
  (func $set_dt (param $x i32) (param $y i32) (param $v i32)
    (i32.store (i32.add (global.get $dt_offset) (i32.mul 
      (i32.add (i32.mul (global.get $m) (local.get $y)) (local.get $x)) 
      (i32.const 4)
    )) (local.get $v))
  )
  ;; read g matrix at coordinate
  (func $get_g (param $x i32) (param $y i32) (result i32)
    (i32.load (i32.add (global.get $g_offset) (i32.mul 
      (i32.add (i32.mul (global.get $m) (local.get $y)) (local.get $x)) 
      (i32.const 4)
    )))
  )
  ;; write g matrix at coordinate
  (func $set_g (param $x i32) (param $y i32) (param $v i32) 
    (i32.store (i32.add (global.get $g_offset) (i32.mul 
      (i32.add (i32.mul (global.get $m) (local.get $y)) (local.get $x)) 
      (i32.const 4)
    )) (local.get $v))
  )
  ;; read s vector at coordinate
  (func $get_s (param $q i32) (result i32)
    (i32.load (i32.add (global.get $s_offset) 
      (i32.mul  (local.get $q) (i32.const 4))
    ))
  )
  ;; write s vector at coordinate
  (func $set_s (param $q i32) (param $v i32)
    (i32.store (i32.add (global.get $s_offset) 
      (i32.mul  (local.get $q) (i32.const 4))
    ) (local.get $v))
  )
  ;; read t vector at coordinate
  (func $get_t (param $q i32)  (result i32)
    (i32.load (i32.add (global.get $t_offset) 
      (i32.mul  (local.get $q) (i32.const 4))
    ))
  )
  ;; write t vector at coordinate
  (func $set_t (param $q i32) (param $v i32)
    (i32.store (i32.add (global.get $t_offset) 
      (i32.mul  (local.get $q) (i32.const 4))
    ) (local.get $v))
  )

  ;; f(x,i) = (x-i)^2+g(i)^2
  (func $edt_f (param $x i32) (param $i i32) (param $y i32) (result i32)
    (local $gi  i32) ;; g(i)=G(i,y)
    (local $x_i i32)
    (local.set $gi (call $get_g (local.get $i) (local.get $y)))
    (local.set $x_i (i32.sub (local.get $x) (local.get $i)))
    (i32.add 
      (i32.mul (local.get $x_i) (local.get $x_i))
      (i32.mul (local.get $gi) (local.get $gi))
    )
  )
  ;; Sep(i,u) = (u^2 - i^2 - g(u)^2 - g(i)^2 ) div (2(u-i))
  (func $edt_sep (param $i i32) (param $u i32) (param $y i32) (result i32)
    (local $gi  i32) ;; g(i)=G(i,y)
    (local $gu  i32)
    (local.set $gi (call $get_g (local.get $i) (local.get $y)))
    (local.set $gu (call $get_g (local.get $u) (local.get $y)))
    (i32.div_u
      (i32.sub
        (i32.add
          (i32.sub
            (i32.mul (local.get $u) (local.get $u))
            (i32.mul (local.get $i) (local.get $i))
          )
          (i32.mul (local.get $gu) (local.get $gu))
        )
        (i32.mul (local.get $gi) (local.get $gi))
      )
      (i32.mul (i32.const 2)
        (i32.sub (local.get $u) (local.get $i))
      )
    )
  )

  ;; setup: specify width and height of input image
  ;; (call before dist_transform())
  (func $setup (param $w i32) (param $h i32)
    (global.set $m (local.get $w))
    (global.set $n (local.get $h))

    ;; memory offsets are all computed here
    (global.set $dt_offset (i32.mul (local.get $w) (local.get $h)))
    (global.set $g_offset  (i32.mul (global.get $dt_offset) (i32.const 5)))
    (global.set $s_offset  (i32.mul (global.get $dt_offset) (i32.const 9)))
    (global.set $t_offset  (i32.add 
      (global.get $s_offset) 
      (i32.mul (local.get $w) (i32.const 4))
    ))

  )

  ;; main distance transform algorithm
  ;; before calling:
  ;; - use setup()  for initialization
  ;; - use set_b()  for setting pixels of the image
  ;; after calling:
  ;; - use get_dt() for reading output
  (func $dist_transform
    ;; this implementation is a verbatim translation of pseudocode described in
    ;; http://fab.cba.mit.edu/classes/S62.12/docs/Meijster_distance.pdf

    ;; local variables
    ;; variables from the paper
    (local $x i32)
    (local $y i32)
    (local $q i32)
    (local $u i32)
    (local $w i32)
    ;; temporary computation results
    (local $gxy1 i32)

    ;; FIRST PHASE

    ;; forall x E [0..m-1] do
    (local.set $x (i32.const 0))
    loop $phase1

      ;; if b[x,0] then
      ;;   g[x,0] := 0
      ;; else
      ;;   g[x,0] := infinity
      ;; endif
      (if (call $get_b (local.get $x) (i32.const 0)) (then
        (call $set_g (local.get $x) (i32.const 0) (i32.const 0))
      )(else
        (call $set_g (local.get $x) (i32.const 0) (i32.add (global.get $m) (global.get $n)))
      ))

      ;; for y := 1 to n-1 do
      ;;   if b[x,y] then
      ;;     g[x,y] := 0
      ;;   else
      ;;     g[x,y] := 1 + g[x,y-1]
      ;;   endif
      (local.set $y (i32.const 1))
      loop $scan1
        (if (call $get_b (local.get $x) (local.get $y)) (then
          (call $set_g (local.get $x) (local.get $y) (i32.const 0))
        )(else
          (call $set_g (local.get $x) (local.get $y) 
            (i32.add (i32.const 1) 
              (call $get_g (local.get $x) (i32.sub (local.get $y) (i32.const 1)) )
            )
          )
        ))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br_if $scan1 (i32.lt_u (local.get $y) (global.get $n)))
      end

      ;; for y := n-2 downto 0 do
      ;;   if g[x,y+1] < g[x,y] then
      ;;     g[x,y] := (1 + g[x,y+1])
      ;;   endif
      (local.set $y (i32.sub (global.get $n) (i32.const 2)))
      loop $scan2
        (local.set $gxy1 
          (call $get_g (local.get $x) (i32.add (local.get $y) (i32.const 1)))
        )
        (if (i32.lt_u (local.get $gxy1)
          (call $get_g (local.get $x) (local.get $y)))
        (then
          (call $set_g (local.get $x) (local.get $y)
            (i32.add (i32.const 1) (local.get $gxy1))
          )
        ))
        (local.set $y (i32.sub (local.get $y) (i32.const 1)))
        (br_if $scan2 (i32.gt_s (local.get $y) (i32.const -1)))
      end

      (local.set $x (i32.add (local.get $x) (i32.const 1)))
      (br_if $phase1 (i32.lt_u (local.get $x) (global.get $m)))
    end

    ;; SECOND PHASE

    ;; forall y E [0..n-1] do
    (local.set $y (i32.const 0))
    loop $phase2
      ;; q := 0; s[0] := 0; t[0] := 0;
      (local.set $q (i32.const 0))
      (call $set_s (i32.const 0) (i32.const 0))
      (call $set_t (i32.const 0) (i32.const 0))

      ;; for u := 1 to m-1 do (* scan 3 *)
      ;;   while q >= 0 ^ f(t[q],s[q]) > f(t[q],u) do
      ;;     q := q - 1
      ;;   if q < 0 then
      ;;     q := 0; s[0] := u
      ;;   else
      ;;     w := 1 + Sep(q[q],u)
      ;;     if w < m then
      ;;       q := q + 1; s[q] := u; t[q] := w
      ;;     end if
      ;;   end if
      ;; end for
      (local.set $u (i32.const 1))
      loop $scan3
        loop $while
          (if (i32.and
            (i32.gt_s (local.get $q) (i32.const -1))
            (i32.gt_s 
              (call $edt_f (call $get_t (local.get $q)) (call $get_s (local.get $q)) (local.get $y))
              (call $edt_f (call $get_t (local.get $q)) (local.get $u) (local.get $y))
            )
          )(then
            (local.set $q (i32.sub (local.get $q) (i32.const 1)))
            (br $while)
          ))
        end
        (if (i32.lt_s (local.get $q) (i32.const 0))(then
          (local.set $q (i32.const 0))
          (call $set_s (i32.const 0) (local.get $u))
        )(else
          (local.set $w (i32.add (i32.const 1)
            (call $edt_sep (call $get_s (local.get $q)) (local.get $u) (local.get $y))
          ))
          (if (i32.lt_u (local.get $w) (global.get $m)) (then
            (local.set $q (i32.add (local.get $q) (i32.const 1)))
            (call $set_s (local.get $q) (local.get $u))
            (call $set_t (local.get $q) (local.get $w))
          ))
        ))

        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br_if $scan3 (i32.lt_u (local.get $u) (global.get $m)))
      end

      ;; for u := m - 1 downto 0 do (* scan 4 *)
      ;;   dt[u,y] := f(u,s[q])
      ;;   if u = t[q] then q := q - 1
      ;; end for
      (local.set $u (i32.sub (global.get $m) (i32.const 1)))
      loop $scan4
        (call $set_dt (local.get $u) (local.get $y)
          (call $edt_f (local.get $u) (call $get_s (local.get $q)) (local.get $y))
        )
        (if (i32.eq (local.get $u) (call $get_t (local.get $q))) (then
          (local.set $q (i32.sub (local.get $q) (i32.const 1)))
        ))
        (local.set $u (i32.sub (local.get $u) (i32.const 1)))
        (br_if $scan4 (i32.gt_s (local.get $u) (i32.const -1)))
      end


      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br_if $phase2 (i32.lt_u (local.get $y) (global.get $n)))
    end
  )


  ;; exported API's
  (export "setup"          (func $setup         ))
  (export "dist_transform" (func $dist_transform))
  (export "set_b"          (func $set_b         ))
  (export "get_dt"         (func $get_dt        ))
  (export "mem"            (memory $mem         ))
)

