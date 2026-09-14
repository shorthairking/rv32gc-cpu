create_clock -period 30.303 -name aclk [get_ports aclk]
set_input_delay  -clock aclk 2.0 [get_ports {aresetn intrpt}\]
set_false_path -from [get_ports aresetn]
