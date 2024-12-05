# run tests, split output to stdout and file
# forge test -vv | tee test_output.log
# above but pass any additional args to forge test
forge test -vv "$@" | tee run_tests.log