
module fp_addsub (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic        sub,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        out_valid,
    output logic [31:0] result
);

    logic sign_a, sign_b;
    logic [7:0] exp_a, exp_b;
    logic [7:0] eff_exp_a, eff_exp_b;
    logic [22:0] frac_a, frac_b;

    logic [23:0] mant_a, mant_b;
    logic [7:0] exp_big, exp_small;
    logic sign_big, sign_small;
    logic [23:0] mant_big, mant_small;

    logic [27:0] ext_a, ext_b;
    logic [27:0] sum;
    logic [27:0] shifted;

    logic result_sign;
    integer exp_diff;
    integer exp_work;
    integer i;

    logic guard_bit;
    logic round_bit;
    logic sticky_bit;
    logic round_up;

    logic [24:0] rounded;

    // Shift right and preserve discarded bits
    function automatic [27:0] shift_right_jam(
        input [27:0] value,
        input integer amount
    );
        logic sticky;
        logic [27:0] mask;

        begin
            sticky = 1'b0;
            mask = 28'b0;

            if (amount <= 0) begin
                shift_right_jam = value;
            end
            else if (amount >= 28) begin
                shift_right_jam = 28'b0;
                shift_right_jam[0] = |value;
            end
            else begin
                mask = 28'hFFFFFFF >> (28 - amount);
                sticky = |(value & mask);

                shift_right_jam = value >> amount;
                shift_right_jam[0] =
                    shift_right_jam[0] | sticky;
            end
        end
    endfunction

    always_comb begin

        // Default values
        sign_a = a[31];
        sign_b = b[31] ^ sub;

        exp_a = a[30:23];
        exp_b = b[30:23];

        frac_a = a[22:0];
        frac_b = b[22:0];

        // Subnormal numbers use effective exponent 1
        eff_exp_a = (exp_a == 0) ? 8'd1 : exp_a;
        eff_exp_b = (exp_b == 0) ? 8'd1 : exp_b;

        out_valid = in_valid && !reset;
        result = 32'b0;

        mant_a = 24'b0;
        mant_b = 24'b0;

        exp_big = 8'b0;
        exp_small = 8'b0;

        sign_big = 1'b0;
        sign_small = 1'b0;

        mant_big = 24'b0;
        mant_small = 24'b0;

        ext_a = 28'b0;
        ext_b = 28'b0;
        sum = 28'b0;
        shifted = 28'b0;

        result_sign = 1'b0;

        exp_diff = 0;
        exp_work = 0;
        i = 0;

        guard_bit = 1'b0;
        round_bit = 1'b0;
        sticky_bit = 1'b0;
        round_up = 1'b0;

        rounded = 25'b0;

        if (in_valid && !reset) begin

            // Handle NaN and infinity
            if ((exp_a == 8'hFF && frac_a != 0) ||
                (exp_b == 8'hFF && frac_b != 0)) begin

                result = 32'h7FC00000;

            end
            else if (exp_a == 8'hFF &&
                     exp_b == 8'hFF &&
                     sign_a != sign_b) begin

                result = 32'h7FC00000;

            end
            else if (exp_a == 8'hFF) begin

                result = {sign_a, 8'hFF, 23'b0};

            end
            else if (exp_b == 8'hFF) begin

                result = {sign_b, 8'hFF, 23'b0};

            end
            else begin

                // Restore hidden bit for normal numbers
                mant_a = (exp_a == 0) ?
                         {1'b0, frac_a} : {1'b1, frac_a};

                mant_b = (exp_b == 0) ?
                         {1'b0, frac_b} : {1'b1, frac_b};

                // Select the larger operand
                if (eff_exp_a > eff_exp_b ||
                    (eff_exp_a == eff_exp_b &&
                     mant_a >= mant_b)) begin

                    exp_big = eff_exp_a;
                    exp_small = eff_exp_b;

                    mant_big = mant_a;
                    mant_small = mant_b;

                    sign_big = sign_a;
                    sign_small = sign_b;

                end
                else begin

                    exp_big = eff_exp_b;
                    exp_small = eff_exp_a;

                    mant_big = mant_b;
                    mant_small = mant_a;

                    sign_big = sign_b;
                    sign_small = sign_a;

                end

                // Align exponents
                exp_diff = exp_big - exp_small;

                ext_a = {mant_big, 3'b000};
                ext_b = {mant_small, 3'b000};

                shifted = shift_right_jam(ext_b, exp_diff);
                ext_b = shifted;

                // Add or subtract mantissas
                if (sign_big == sign_small) begin
                    sum = ext_a + ext_b;
                    result_sign = sign_big;
                end
                else begin
                    sum = ext_a - ext_b;
                    result_sign = sign_big;
                end

                exp_work = exp_big;

                // Normalize result
                if (sum == 0) begin

                    result = {(sign_a & sign_b), 31'b0};

                end
                else begin

                    if (sum[27]) begin
                        sum = shift_right_jam(sum, 1);
                        exp_work = exp_work + 1;
                    end
                    else begin
                        for (i = 0; i < 27; i = i + 1) begin
                            if (!sum[26] && exp_work > 1) begin
                                sum = sum << 1;
                                exp_work = exp_work - 1;
                            end
                        end
                    end

                    // Round to nearest, ties to even
                    guard_bit = sum[2];
                    round_bit = sum[1];
                    sticky_bit = sum[0];

                    round_up = guard_bit &&
                               (round_bit ||
                                sticky_bit ||
                                sum[3]);

                    rounded = {1'b0, sum[26:3]} + round_up;

                    if (rounded[24]) begin
                        rounded = rounded >> 1;
                        exp_work = exp_work + 1;
                    end

                    // Pack the result
                    if (exp_work >= 255) begin
                        result = {result_sign, 8'hFF, 23'b0};
                    end
                    else if (exp_work == 1 && !rounded[23]) begin

                        // Result is subnormal
                        result = {result_sign, 8'b0,
                                  rounded[22:0]};

                    end
                    else begin

                        // Result is normal
                        result = {result_sign, exp_work[7:0],
                                  rounded[22:0]};

                    end

                end
            end
        end
    end

endmodule
