set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
open_checkpoint [file join $OUT_DIR scratch_nofpu_post_synth.dcp]
report_timing -delay_type max -from [get_pins -quiet u_plic/threshold_r_reg[1][0]/Q] \
  -max_paths 3 -nworst 1 -path_type full -input_pins \
  -file [file join $OUT_DIR scratch_nofpu_path1.rpt]
report_timing -delay_type max -to [get_pins -quiet {u_l1d/maint_idx_q_reg[0]/R u_l1d/cap_rd_q_reg[0]/R}] \
  -max_paths 4 -nworst 1 -path_type full -input_pins \
  -file [file join $OUT_DIR scratch_nofpu_path1b.rpt]
report_timing -delay_type max -to [get_pins -quiet {u_axi_master_ctrl/len_q_reg[2]/D}] \
  -max_paths 2 -nworst 1 -path_type full -input_pins \
  -file [file join $OUT_DIR scratch_nofpu_path1c.rpt]
puts "RESULT_PATH1: OK"
exit 0
