###
# Extra GPU subnet in a third AZ (us-east-1c).
#
# Why: the VPC is created with only the first 2 AZs (us-east-1a/1b, see vpc.tf
# `slice(azs,0,2)`). 80GB GPUs we need for the 27B benchmark aren't available
# on-demand in those AZs — H100 (p5.4xlarge) has no capacity there, and A100
# (p4de.24xlarge) is only *offered* in us-east-1c/1d. We can't widen the VPC
# module's AZ list after creation (it reshuffles every private-subnet CIDR =
# destroys the env), so we add ONE standalone subnet in us-east-1c and point the
# GPU node pool at it. Routed through the existing single NAT for image/model
# egress; tagged so EKS treats it as a cluster subnet.
#
# Gated to the jan-inference env so the shared local-inference env is untouched.
###
locals {
  gpu_extra_az_enabled = local.create_vpc && var.deployment_name == "jan-inference"
  # us-east-1c and us-east-1d are the AZs that offer A100 80GB (p4de). Spanning
  # both = two independent on-demand capacity pools to improve launch odds.
  gpu_extra_azs = { "us-east-1c" = "10.0.64.0/20", "us-east-1d" = "10.0.80.0/20" }
  # GPU pool subnets:
  #  - jan-inference (us-east-1): extra 1c/1d subnets (A100 only in c/d there).
  #  - jan-inference-eu (Frankfurt): pin to the FIRST private subnet = eu-central-1a,
  #    the only AZ in the VPC's a/b slice that offers A100 p4de (b does not → the
  #    multi-AZ pool otherwise hits "Unsupported" when the ASG tries b).
  #  - otherwise: all private subnets.
  gpu_subnet_ids = (
    # jan-inference: span ALL four AZs (original 1a/1b private subnets + extra
    # 1c/1d) — four independent on-demand capacity pools. GPU capacity is per-AZ
    # and scarce; the widest net wins (g6e lives in 1a/1b, p4de in 1c/1d).
    local.gpu_extra_az_enabled ? concat(local.private_subnet_ids, [for s in aws_subnet.gpu_extra_az : s.id]) :
    var.deployment_name == "jan-inference-eu" ? [local.private_subnet_ids[0]] :
    local.private_subnet_ids
  )
}

resource "aws_subnet" "gpu_extra_az" {
  for_each          = local.gpu_extra_az_enabled ? local.gpu_extra_azs : {}
  vpc_id            = local.vpc_id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(local.common_tags, {
    Name                                           = "${var.deployment_name}-gpu-${each.key}"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.deployment_name}" = "shared"
  })
}

# Route the extra subnets through the existing private route table (0.0.0.0/0 -> NAT),
# so GPU nodes can pull container images and model weights.
resource "aws_route_table_association" "gpu_extra_az" {
  for_each       = local.gpu_extra_az_enabled ? local.gpu_extra_azs : {}
  subnet_id      = aws_subnet.gpu_extra_az[each.key].id
  route_table_id = element(module.vpc[0].private_route_table_ids, 0)
}
