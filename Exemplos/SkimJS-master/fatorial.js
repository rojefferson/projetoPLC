function fat(n)
{
	if(n ==0) return 1;
	return n *fat(n-1);
}

var x = 5;

fat(x);
