# SPDX-License-Identifier: GPL-3.0-or-later
# in: all.tsv map.tsv reach.tsv ; out: reachcheck.tsv
BEGIN{FS=OFS="\t"}
FILENAME==ARGV[1]{aloc[$1]=$8":"$9; next}
FILENAME==ARGV[2]{ if($2=="field"||$2=="tag") next; n=$1; gsub(/\(\)/,"",n); at[$5]=at[$5] "\x1f" $1; norm[$1]=n; next}
{ nav=$1; L=$6; CL=($7=="-")?L:aloc[$7];
  res="missing"; mp="";
  cand=at[L]; if (CL!=L) cand=cand at[CL];
  k=split(cand, arr, "\x1f");
  for(i=2;i<=k;i++){ if(norm[arr[i]]==nav){res="exact"; mp=arr[i]; break} }
  if(res=="missing" && k>=2){ res="other_path"; mp=arr[2]; for(i=3;i<=k;i++) mp=mp" | "arr[i] }
  print nav,$3,$4,$5,L,CL,res,mp }
