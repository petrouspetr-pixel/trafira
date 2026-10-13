let analyzer=require("diagnostics.route_analysis");
print(sprintf("%J\n",ARGV[0]=="explain"?analyzer.explain(ARGV[1]):{success:false,error:"invalid_command"}));
