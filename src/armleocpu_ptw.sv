module armleocpu_ptw(
    input clk,
    input async_rst_n,

    output logic [33:0] avl_address,
    output logic        avl_read,
    input  [31:0]       avl_readdata,
    input               avl_readdatavalid,
    input               avl_waitrequest,
    input [1:0]         avl_response,
    //                  avl_burstcount = 1
    //                  avl_write = 0
    //                  avl_writedata = 32'hXXXX_XXXX


    input               resolve_request,
    output logic        resolve_ack,
    input [19:0]        virtual_address,

    output logic        resolve_done,
    output logic        resolve_pagefault,
    output logic        resolve_accessfault,

    output logic [7:0]  resolve_access_bits,
    output logic [21:0] resolve_physical_address,

    input               matp_mode,
    input [21:0]        matp_ppn

    `ifdef DEBUG
    , output wire [24:0] state_debug_output
    `endif
);


localparam STATE_IDLE = 1'b0;
localparam STATE_TABLE_WALKING = 1'b1;

localparam false = 1'b0;
localparam true = 1'b1;

reg state;
reg read_issued;
reg current_level;
reg [21:0] current_table_base;
reg [19:0] saved_virtual_address;

// local states


`ifdef DEBUG
assign state_debug_output = {current_table_base, current_level, read_issued, state};
`endif
wire [9:0] virtual_address_vpn[1:0];
assign virtual_address_vpn[0] = saved_virtual_address[9:0];
assign virtual_address_vpn[1] = saved_virtual_address[19:10];

// PTE Decoding
wire pte_valid   = avl_readdata[0];
wire pte_read    = avl_readdata[1];
wire pte_write   = avl_readdata[2];
wire pte_execute = avl_readdata[3];

wire [11:0] pte_ppn0 = avl_readdata[31:20];
wire [9:0]  pte_ppn1 = avl_readdata[19:10];

wire pte_invalid = !pte_valid || (!pte_read && pte_write);
wire pte_missaligned = current_level == 1 && pte_ppn1 != 0;
        // missaligned if current level is zero is impossible
wire pte_is_leaf = pte_read || pte_execute;
wire pte_pointer = avl_readdata[3:0] == 4'b0001;

// Avalon-MM Bus

wire pma_error = (avl_response != 2'b00);

assign avl_address = {current_table_base, virtual_address_vpn[current_level], 2'b00};
assign avl_read = !read_issued && state == STATE_TABLE_WALKING;


// Resolve resolved physical address
assign resolve_physical_address = {avl_readdata[31:20],
    current_level ? saved_virtual_address[9:0] : avl_readdata[19:10]
};
// resolved access bits
assign resolve_access_bits = avl_readdata[7:0];
// resolve request was accepted
assign resolve_ack = state == STATE_IDLE;

`ifdef DEBUG
task debug_write_all; begin
    debug_write_request();
    debug_write_state();
    debug_write_pte();
end endtask

task debug_write_request(); begin
    $display($time, " [PTW]\tRequested virtual address = 0x%H", {saved_virtual_address, 12'hXXX});
end endtask

task debug_write_state(); begin
    $display($time, " [PTW]\tstate = %s, current_level = %s, current_table_base = 0x%X",
            state == 1 ? "IDLE" : "TABLE_WALKING",
            current_level ? "megapage": "page",
            {current_table_base, 12'hXXX});
end endtask

task debug_write_pte(); begin
    $display($time, " [PTW]\tPTE value = 0x%X, avl_response = %s, avl_address = 0x%X", avl_readdata, avl_response == 2'b00 ? "VALID": "ERROR", avl_address);
    $display($time, " [PTW]\tvalid? = %s, access_bits = %s%s%s\t", pte_valid ? "VALID" : "INVALID", (pte_read ? "r" : " "), (pte_write ? "w" : " "), (pte_execute ? "x" : " "));
    $display($time, " [PTW]\tpte_ppn0 = 0x%X, pte_ppn1 = 0x%X", pte_ppn0, pte_ppn1);
    if(pma_error) begin
                                $display($time, " [PTW]\tPMA_Error");
    end else if(pte_invalid) begin
                                $display($time, " [PTW]\tPTE_Invalid");
    end else if(pte_is_leaf) begin
        if(!pte_missaligned)    $display($time, " [PTW]\tAligned page");
        else                    $display($time, " [PTW]\tMissaligned megapage");
    end else if(pte_pointer) begin
        if(current_level)       $display($time, " [PTW]\tGoing deeper");
        else                    $display($time, " [PTW]\tPage leaf expected, insted pointer found");
    end
end endtask
`endif



always @* begin
    resolve_done = false;
    resolve_pagefault = false;
    resolve_accessfault = false;
    case(state)
        STATE_IDLE: begin

        end
        STATE_TABLE_WALKING: begin
            if(!avl_waitrequest && avl_readdatavalid) begin
                if(pma_error) begin
                    resolve_accessfault = true;
                    resolve_done = true;
                end else if(pte_invalid) begin
                    resolve_pagefault = true;
                    resolve_done = true;
                end else if(pte_is_leaf) begin
                    if(pte_missaligned) begin
                        resolve_pagefault = true;
                        resolve_done = true;
                    end else if(!pte_missaligned) begin
                        resolve_done = true;
                    end
                end else if(pte_pointer) begin
                    if(current_level == 1'b0) begin
                        resolve_pagefault = true;
                        resolve_done = true;
                    end
                    //else if(current_level == 1'b1) begin end;  
                end
            end
        end
    endcase
end

always @(posedge clk or negedge async_rst_n) begin
    if(!async_rst_n) begin
        state <= STATE_IDLE;
    end else if(clk) begin
        case(state)
            STATE_IDLE: begin
                read_issued <= false;
                current_level <= 1'b1;
                saved_virtual_address <= virtual_address;
                current_table_base <= matp_ppn;
                if(resolve_request) begin
                    state <= STATE_TABLE_WALKING;
                    `ifdef DEBUG
                    $display("[PTW] Page table walk request for address = 0x%X, w/ matp_mode = %b", {virtual_address, 12'hXXX}, matp_mode);
                    `endif
                end
            end
            STATE_TABLE_WALKING: begin
                if(!avl_waitrequest)
                    read_issued <= true;
                if(!avl_waitrequest && avl_readdatavalid) begin
                    if(pma_error) begin
                        state <= STATE_IDLE;
                        `ifdef DEBUG
                        $display("[PTW] Request failed because of PMA");
                        debug_write_all();
                        `endif
                    end else if(pte_invalid) begin
                        state <= STATE_IDLE;
                        `ifdef DEBUG
                        $display("[PTW] Request failed because PTE");
                        debug_write_all();
                        `endif
                    end else if(pte_is_leaf) begin
                        state <= STATE_IDLE;
                        if(pte_missaligned) begin
                            `ifdef DEBUG
                            $display("[PTW] Request failed because PTE is missalligned");
                            debug_write_all();
                            `endif
                        end else if(!pte_missaligned) begin
                            `ifdef DEBUG
                            $display("[PTW] Request successful completed");
                            debug_write_all();
                            `endif
                        end
                    end else if(pte_pointer) begin
                        if(current_level == 1'b0) begin
                            state <= STATE_IDLE;
                            `ifdef DEBUG
                            $display("[PTW] Resolve pagefault");
                            debug_write_all();
                            `endif
                        end else if(current_level == 1'b1) begin
                            current_level <= 1'b0;
                            read_issued <= false;
                            current_table_base <= avl_readdata[31:10];
                            `ifdef DEBUG
                            $display("[PTW] Resolve going to next level");
                            debug_write_all();
                            `endif
                        end
                    end
                end
            end
        endcase
    end
end



endmodule