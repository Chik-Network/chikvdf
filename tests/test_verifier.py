from chiavdf import prove, verify_wesolowski, verify_n_wesolowski, create_discriminant
import secrets
import time


def test_prove_and_verify():
    discriminant_challenge = secrets.token_bytes(10)
    discriminant_size = 512
    discriminant = create_discriminant(discriminant_challenge, discriminant_size)
    int_size = (discriminant_size + 16) >> 4

    iters = 1000000
    t1 = time.time()
    result = prove(discriminant_challenge, str(2), str(1), discriminant_size, iters)
    t2 = time.time()
    print(f"IPS: {iters / (t2 - t1)}")
    result_y_a = int.from_bytes(
        result[0:int_size],
        "big",
        signed=True,
    )
    result_y_b = int.from_bytes(
        result[int_size : 2 * int_size],
        "big",
        signed=True,
    )
    proof_a = int.from_bytes(
        result[2 * int_size : 3 * int_size],
        "big",
        signed=True,
    )
    proof_b = int.from_bytes(
        result[3 * int_size : 4 * int_size],
        "big",
        signed=True,
    )

    is_valid = verify_wesolowski(
        str(discriminant),
        str(2),
        str(1),
        str(result_y_a),
        str(result_y_b),
        str(proof_a),
        str(proof_b),
        iters,
    )
    assert is_valid

    # Creates another proof starting at the previous output
    iters_2 = 200000
    t1 = time.time()
    result_2 = prove(
        discriminant_challenge,
        str(result_y_a),
        str(result_y_b),
        discriminant_size,
        iters_2,
    )
    t2 = time.time()
    print(f"IPS: {iters_2 / (t2 - t1)}")

    is_valid = verify_wesolowski(
        str(discriminant),
        str(result_y_a),
        str(result_y_b),
        str(
            int.from_bytes(
                result_2[0:int_size],
                "big",
                signed=True,
            )
        ),
        str(
            int.from_bytes(
                result_2[int_size : 2 * int_size],
                "big",
                signed=True,
            )
        ),
        str(
            int.from_bytes(
                result_2[2 * int_size : 3 * int_size],
                "big",
                signed=True,
            )
        ),
        str(
            int.from_bytes(
                result_2[3 * int_size : 4 * int_size],
                "big",
                signed=True,
            )
        ),
        iters_2,
    )
    assert is_valid

    is_valid = verify_n_wesolowski(
        "-13165332425413863665316386141433169830553109022149646" +
            "79273603266867151809660942505983218996212499722203" +
            "87687148397451395672779897144571112116763666653213" +
            "74847390954748243724640501870747215329011622707282" +
            "54476433245305090167784327698023009134612851283391" +
            "19844239772697652504835780459732685000796733645621" +
            "728639",
        "2",
        "1",
        bytes.fromhex("003f360be667de706fe886f766fe20240de04fe2" +
            "c2f91207f1bbdddf20c554ab8d168b2ce9664d75f4613375a0" +
            "ab12bf8158983574c9f5cd61c6b8a905fd3fa6bbffc5401b4c" +
            "cedbe093b560293263a226e46302e720726586251116bc689e" +
            "f09dc70d99e0a090c4409f928e218e85032fdbee02fedd5630" +
            "73be555b75a70a2d6a430033bc7a4926e3504e87698a0ace0d" +
            "ee6364cced2e9142b4e4cbe55a6371aab41e501ceed21d79d3" +
            "a0dbbd82ce913c5de40b13eb7c59b1b52b6ef270ee603bd5e7" +
            "fffcc9f5fae6dbd5aeec394181af130c0fdd195b22be745449" +
            "b7a584ac80fc75ed49acfdb4d650f5cd344f86377ebbbaef5b" +
            "19a0af3ae08101d1697f5656a52193000000000071c6f40024" +
            "c342868a0c2a201b1b26a5d52c5d2f92a106c19ff926deb3fb" +
            "a1e74a444ecee3f8f507c062b949a2eaadd442b049417f82e8" +
            "811526fa83c6d099d75323e068ffeca9dcd163761000c65d21" +
            "dede72787ac350f25bdd3d29db6e9cb0e22c8124c724db3366" +
            "0c88784e2871b62ecf816846db7b469c71cad9a5dcfc5548ed" +
            "2dd781006fa15b968facf4d79219646267eb187a670306d1ff" +
            "1a59fc28ae00d36bb5a1cba659f48aa64a9022711a66105ef1" +
            "4401ff3948add265240aaad329ee76ba4c2300496746b86bcc" +
            "cacff5947c3fcb956cde2cffae10435960d7097f989aac742c" +
            "f1047887f11584d20297958385e1715fe0f9b69141750c20d8" +
            "134420eafec68fd10000000001555540006958aabfe4cc5d87" +
            "0e61fef82bcf1f2c3859e2bd8b1177e8a8872376b5cabace5d" +
            "cb59b6fecada7e522d05f6f0e352939a6bfdf8c454fbe822cf" +
            "a5ce97d17be0ffde44a4812cde9d04ec5c08dce6f9146586fd" +
            "c8e081e05ec690b7effe24ea756f3d300f361203b61e1a3922" +
            "0c6eafa7852842674e317dcae5549c78c7144296ff004a6d0d" +
            "2854c55e4c1de2f17dc4480b81652cfec37124ef41560a28c8" +
            "53482732434d1c006763b2e341528ae0bcc29fb76f1a4dafd9" +
            "9ade4fd75ec9cc9ca3f3d7001bcb6eb71e43eb22169ab72163" +
            "7551a8ec93838eb0825e9ecba9175297a00b146e9fdd244c5b" +
            "722f29d3c46ec38840ba18f1f06ddec3dea844867386c2e1ac" +
            "95"),
        33554432,
        1024,
        2,
    )
    assert is_valid
